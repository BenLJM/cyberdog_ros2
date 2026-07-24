/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "hsp-combo.h"

#include <linux/version.h>

#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/pm_runtime.h>
#include <linux/slab.h>
#include <linux/mailbox_client.h>
#include <linux/sched.h>
#include <linux/sched/clock.h>
#include <linux/err.h>

#include "soc/tegra/camrtc-commands.h"

/*
 * Legacy SM5 command ids dropped from the R35 camrtc-commands.h (turned
 * into RTCPU_CMD_RESERVED_0x when hsp-combo legacy support was removed).
 * The factory R32-era RCE firmware still answers on these fixed ABI values.
 */
#ifndef RTCPU_CMD_PING
#define RTCPU_CMD_PING		MK_U32(3)
#endif
#ifndef RTCPU_CMD_FW_HASH
#define RTCPU_CMD_FW_HASH	MK_U32(5)
#endif

typedef struct mbox_client mbox_client;
struct camrtc_hsp_mbox {
	struct mbox_client client;
	struct mbox_chan* chan;
};

struct camrtc_hsp_op;

struct camrtc_hsp {
	const struct camrtc_hsp_op *op;
	struct camrtc_hsp_mbox rx;
	struct camrtc_hsp_mbox tx;
	struct camrtc_hsp_mbox ivc_tx;
	struct camrtc_hsp_mbox ivc_rx;
	u32 cookie;
	spinlock_t sendlock;
	void (*group_notify)(struct device *dev, u16 group);
	struct device dev;
	struct mutex mutex;
	struct completion emptied;
	wait_queue_head_t response_waitq;
	atomic_t response;
	long timeout;
};

struct camrtc_hsp_op {
	int (*send)(struct camrtc_hsp *, int msg, long *timeout);
	void (*group_ring)(struct camrtc_hsp *, u16 group);
	int (*sync)(struct camrtc_hsp *, long *timeout);
	int (*resume)(struct camrtc_hsp *, long *timeout);
	int (*suspend)(struct camrtc_hsp *, long *timeout);
	int (*bye)(struct camrtc_hsp *, long *timeout);
	int (*ch_setup)(struct camrtc_hsp *, dma_addr_t iova, long *timeout);
	int (*ping)(struct camrtc_hsp *, u32 data, long *timeout);
	int (*get_fw_hash)(struct camrtc_hsp *, u32 index, long *timeout);
};

static int camrtc_hsp_send(struct camrtc_hsp *camhsp,
		int request, long *timeout)
{
	int ret = camhsp->op->send(camhsp, request, timeout);

	if (ret == -ETIME) {
		dev_err(&camhsp->dev,
			"request 0x%08x: empty mailbox timeout\n", request);
	}
	else if (ret == -EINVAL) {
		dev_err(&camhsp->dev,
			"request 0x%08x: invalid mbox channel\n", request);
	}
	else if (ret == -ENOBUFS) {
		dev_err(&camhsp->dev,
			"request 0x%08x: no space left in mbox msg queue\n", request);
	}
	else
		dev_dbg(&camhsp->dev,
			"request sent: 0x%08x\n", request);

	return ret;
}

static int camrtc_hsp_recv(struct camrtc_hsp *camhsp,
		int command, long *timeout)
{
	int response;

	*timeout = wait_event_timeout(
		camhsp->response_waitq,
		(response = atomic_xchg(&camhsp->response, -1)) >= 0,
		*timeout);
	if (*timeout <= 0) {
		dev_err(&camhsp->dev,
			"request 0x%08x: response timeout\n", command);
		return -ETIMEDOUT;
	}

	dev_dbg(&camhsp->dev, "request 0x%08x: response 0x%08x\n",
		command, response);

	return response;
}

static int camrtc_hsp_sendrecv(struct camrtc_hsp *camhsp,
		int command, long *timeout)
{
	int response;
	response = camrtc_hsp_send(camhsp, command, timeout);
	if (response >= 0)
		response = camrtc_hsp_recv(camhsp, command, timeout);

	return response;
}

/* ---------------------------------------------------------------------- */
/* Protocol nvidia,tegra186-hsp-mailbox (legacy SM5 command protocol),      */
/* reimplemented over the generic Linux mailbox framework so the R35 kernel  */
/* can talk to the factory R32-era RCE firmware without reflashing.          */
/* Uses shared-mailbox TX/RX channels (cmd = SM 6, ivc = SM 1) exactly like  */
/* the vm path above, but with the SM5 RTCPU_COMMAND message format.         */

static void camrtc_hsp_legacy_rx_notify(mbox_client *cl, void *data)
{
	struct camrtc_hsp *camhsp = dev_get_drvdata(cl->dev);
	u32 msg = (u32)(unsigned long)data;

	/*
	 * Legacy SM5 responses carry RTCPU_CMD ids (< CAMRTC_HSP_HELLO); unlike
	 * the vm rx path we must NOT filter them out. Just record and wake.
	 */
	atomic_set(&camhsp->response, msg);
	wake_up(&camhsp->response_waitq);
}

static void camrtc_hsp_legacy_ivc_notify(mbox_client *cl, void *data)
{
	struct camrtc_hsp *camhsp = dev_get_drvdata(cl->dev);

	(void)data;
	/* Legacy has no per-group shared semaphore: notify all IVC groups. */
	camhsp->group_notify(camhsp->dev.parent, (u16)0xFFFFU);
}

static int camrtc_hsp_cmd_send(struct camrtc_hsp *camhsp, int request,
		long *timeout);
static void camrtc_hsp_cmd_group_ring(struct camrtc_hsp *camhsp, u16 group);
static int camrtc_hsp_cmd_sync(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_init(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_fw_version(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_resume(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_suspend(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_bye(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_cmd_ch_setup(struct camrtc_hsp *camhsp,
		dma_addr_t iova, long *timeout);
static int camrtc_hsp_cmd_ping(struct camrtc_hsp *camhsp,
		u32 data, long *timeout);
static int camrtc_hsp_cmd_get_fw_hash(struct camrtc_hsp *camhsp, u32 index,
		long *timeout);

static const struct camrtc_hsp_op camrtc_hsp_cmd_ops = {
	.send = camrtc_hsp_cmd_send,
	.group_ring = camrtc_hsp_cmd_group_ring,
	.sync = camrtc_hsp_cmd_sync,
	.resume = camrtc_hsp_cmd_resume,
	.suspend = camrtc_hsp_cmd_suspend,
	.bye = camrtc_hsp_cmd_bye,
	.ping = camrtc_hsp_cmd_ping,
	.ch_setup = camrtc_hsp_cmd_ch_setup,
	.get_fw_hash = camrtc_hsp_cmd_get_fw_hash,
};

static int camrtc_hsp_cmd_send(struct camrtc_hsp *camhsp,
		int request, long *timeout)
{
	int response;
	unsigned long flags;

	spin_lock_irqsave(&camhsp->sendlock, flags);
	atomic_set(&camhsp->response, -1);
	response = mbox_send_message(camhsp->tx.chan,
			(void *)(unsigned long)request);
	spin_unlock_irqrestore(&camhsp->sendlock, flags);

	return response < 0 ? response : 0;
}

static void camrtc_hsp_cmd_group_ring(struct camrtc_hsp *camhsp,
		u16 group)
{
	unsigned long flags;

	(void)group;
	spin_lock_irqsave(&camhsp->sendlock, flags);
	(void)mbox_send_message(camhsp->ivc_tx.chan, (void *)(unsigned long)1);
	spin_unlock_irqrestore(&camhsp->sendlock, flags);
}

static int camrtc_hsp_command(struct camrtc_hsp *camhsp,
		u32 command, long *timeout)
{
	int response;

	response = camrtc_hsp_sendrecv(camhsp, command, timeout);

	return response;
}

static int camrtc_hsp_cmd_sync(struct camrtc_hsp *camhsp, long *timeout)
{
	int ret = camrtc_hsp_cmd_init(camhsp, timeout);

	if (ret >= 0)
		ret = camrtc_hsp_cmd_fw_version(camhsp, timeout);

	return ret;
}

static int camrtc_hsp_cmd_init(struct camrtc_hsp *camhsp, long *timeout)
{
	struct device *dev = &camhsp->dev;
	u32 command = RTCPU_COMMAND(INIT, 0);
	int ret = camrtc_hsp_sendrecv(camhsp, command, timeout);

	if (ret < 0)
		return ret;

	if (ret != command) {
		dev_err(dev, "RTCPU sync problem (response=0x%08x)\n", ret);
		return -EIO;
	}

	return 0;
}

static int camrtc_hsp_cmd_fw_version(struct camrtc_hsp *camhsp, long *timeout)
{
	u32 command = RTCPU_COMMAND(FW_VERSION, RTCPU_DRIVER_SM5_VERSION);
	u32 response = camrtc_hsp_sendrecv(camhsp, command, timeout);

	if (response < 0)
		return response;

	if (RTCPU_GET_COMMAND_ID(response) != RTCPU_CMD_FW_VERSION ||
		RTCPU_GET_COMMAND_VALUE(response) < RTCPU_FW_SM4_VERSION) {
		dev_err(&camhsp->dev,
			"RTCPU version mismatch (response=0x%08x)\n", response);
		return -EIO;
	}

	return (int)RTCPU_GET_COMMAND_VALUE(response);
}

static int camrtc_hsp_cmd_resume(struct camrtc_hsp *camhsp, long *timeout)
{
	return camrtc_hsp_cmd_fw_version(camhsp, timeout);
}

static int camrtc_hsp_cmd_suspend(struct camrtc_hsp *camhsp, long *timeout)
{
	u32 command = RTCPU_COMMAND(PM_SUSPEND, 0);
	int expect = RTCPU_COMMAND(PM_SUSPEND, RTCPU_PM_SUSPEND_SUCCESS);
	int response = camrtc_hsp_command(camhsp, command, timeout);

	if (response == expect)
		return 0;

	return response != 0 ? response : -EIO;
}

static int camrtc_hsp_cmd_bye(struct camrtc_hsp *camhsp, long *timeout)
{
	u32 command = RTCPU_COMMAND(PM_SUSPEND, 1);
	int expect = RTCPU_COMMAND(PM_SUSPEND, RTCPU_PM_SUSPEND_SUCCESS);
	int response = camrtc_hsp_command(camhsp, command, timeout);

	if (response == expect)
		return 0;

	return response != 0 ? response : -EIO;
}

static int camrtc_hsp_cmd_ch_setup(
	struct camrtc_hsp *camhsp, dma_addr_t iova, long *timeout)
{
	u32 command = RTCPU_COMMAND(CH_SETUP, iova >> 8);
	int response = camrtc_hsp_command(camhsp, command, timeout);

	if (response < 0)
		return response;

	if (RTCPU_GET_COMMAND_ID(response) == RTCPU_CMD_ERROR)
		return (int)RTCPU_GET_COMMAND_VALUE(response);

	return 0;
}

static int camrtc_hsp_cmd_ping(
	struct camrtc_hsp *camhsp, u32 data, long *timeout)
{
	u32 command = RTCPU_COMMAND(PING, data & 0xffffffU);
	int response = camrtc_hsp_command(camhsp, command, timeout);

	if (response >= 0)
		response = RTCPU_GET_COMMAND_VALUE(response);

	return response;
}

static int camrtc_hsp_cmd_get_fw_hash(struct camrtc_hsp *camhsp,
		u32 index, long *timeout)
{
	u32 command = RTCPU_COMMAND(FW_HASH, index);
	int ret = camrtc_hsp_command(camhsp, command, timeout);

	if (ret >= 0 && RTCPU_GET_COMMAND_ID(ret) == RTCPU_CMD_FW_HASH)
		return (int)RTCPU_GET_COMMAND_VALUE(ret);
	else
		return -EIO;
}

static int camrtc_hsp_cmd_probe(struct camrtc_hsp *camhsp)
{
	struct device_node *np = camhsp->dev.parent->of_node;
	int err = -ENOTSUPP;
	const char *obtain = "";

	np = of_get_compatible_child(np, "nvidia,tegra186-hsp-mailbox");
	if (!of_device_is_available(np)) {
		dev_info(&camhsp->dev, "no hsp protocol \"%s\"\n",
			"nvidia,tegra186-hsp-mailbox");
		of_node_put(np);
		return -ENOTSUPP;
	}

	camhsp->dev.of_node = np;

	/* cmd response path must not apply the vm SM6 HELLO filter */
	camhsp->rx.client.rx_callback = camrtc_hsp_legacy_rx_notify;

	camhsp->tx.chan = mbox_request_channel_byname(&camhsp->tx.client,
			obtain = "cmd-tx");
	if (IS_ERR(camhsp->tx.chan)) {
		err = PTR_ERR(camhsp->tx.chan);
		goto fail;
	}

	camhsp->rx.chan = mbox_request_channel_byname(&camhsp->rx.client,
			obtain = "cmd-rx");
	if (IS_ERR(camhsp->rx.chan)) {
		err = PTR_ERR(camhsp->rx.chan);
		goto fail;
	}

	camhsp->ivc_tx.client.dev = &camhsp->dev;
	camhsp->ivc_tx.client.tx_block = false;
	camhsp->ivc_tx.chan = mbox_request_channel_byname(&camhsp->ivc_tx.client,
			obtain = "ivc-tx");
	if (IS_ERR(camhsp->ivc_tx.chan)) {
		err = PTR_ERR(camhsp->ivc_tx.chan);
		goto fail;
	}

	camhsp->ivc_rx.client.dev = &camhsp->dev;
	camhsp->ivc_rx.client.rx_callback = camrtc_hsp_legacy_ivc_notify;
	camhsp->ivc_rx.chan = mbox_request_channel_byname(&camhsp->ivc_rx.client,
			obtain = "ivc-rx");
	if (IS_ERR(camhsp->ivc_rx.chan)) {
		err = PTR_ERR(camhsp->ivc_rx.chan);
		goto fail;
	}

	camhsp->op = &camrtc_hsp_cmd_ops;
	dev_set_name(&camhsp->dev, "%s:%s",
		dev_name(camhsp->dev.parent), camhsp->dev.of_node->name);
	dev_dbg(&camhsp->dev, "probed (legacy hsp-mailbox)\n");

	return 0;

fail:
	if (err != -EPROBE_DEFER)
		dev_err(&camhsp->dev, "%s: failed to obtain %s: %d\n",
			np->name, obtain, err);
	of_node_put(np);
	return err;
}

/* ---------------------------------------------------------------------- */
/* Protocol nvidia,tegra-camrtc-hsp-vm */

static void camrtc_hsp_rx_full_notify(mbox_client* cl, void *data)
{
	struct camrtc_hsp *camhsp = dev_get_drvdata(cl->dev);
	u32 status, group;

	u32 msg = (u32) (unsigned long) data;
	status = CAMRTC_HSP_SS_FW_MASK;
	status >>= CAMRTC_HSP_SS_FW_SHIFT;
	group = status & CAMRTC_HSP_SS_IVC_MASK;

	if (CAMRTC_HSP_MSG_ID(msg) == CAMRTC_HSP_UNKNOWN)
		dev_dbg(&camhsp->dev,"request message unknown 0x%08x\n", msg);

	if (group != 0)
		camhsp->group_notify(camhsp->dev.parent, (u16)group);

	/* Other interrupt bits are ignored for now */

	if (CAMRTC_HSP_MSG_ID(msg) == CAMRTC_HSP_IRQ) {
		/* We are done here */
	} else if (CAMRTC_HSP_MSG_ID(msg) < CAMRTC_HSP_HELLO) {
		/* Rest of the unidirectional messages are now ignored */
		dev_info(&camhsp->dev, "unknown message 0x%08x\n", msg);
	} else {
		atomic_set(&camhsp->response, msg);
		wake_up(&camhsp->response_waitq);
	}
}

static void camrtc_hsp_tx_empty_notify(mbox_client* cl, void *data, int empty_value)
{
	struct camrtc_hsp *camhsp = dev_get_drvdata(cl->dev);

	(void)empty_value;	/* ignored */

	complete(&camhsp->emptied);
}

static int camrtc_hsp_vm_send(struct camrtc_hsp *camhsp,
		int request, long *timeout);
static void camrtc_hsp_vm_group_ring(struct camrtc_hsp *camhsp, u16 group);
static void camrtc_hsp_vm_send_irqmsg(struct camrtc_hsp *camhsp);
static int camrtc_hsp_vm_sync(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_hello(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_protocol(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_resume(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_suspend(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_bye(struct camrtc_hsp *camhsp, long *timeout);
static int camrtc_hsp_vm_ch_setup(struct camrtc_hsp *camhsp,
		dma_addr_t iova, long *timeout);
static int camrtc_hsp_vm_ping(struct camrtc_hsp *camhsp,
		u32 data, long *timeout);
static int camrtc_hsp_vm_get_fw_hash(struct camrtc_hsp *camhsp,
		u32 index, long *timeout);

static const struct camrtc_hsp_op camrtc_hsp_vm_ops = {
	.send = camrtc_hsp_vm_send,
	.group_ring = camrtc_hsp_vm_group_ring,
	.sync = camrtc_hsp_vm_sync,
	.resume = camrtc_hsp_vm_resume,
	.suspend = camrtc_hsp_vm_suspend,
	.bye = camrtc_hsp_vm_bye,
	.ping = camrtc_hsp_vm_ping,
	.ch_setup = camrtc_hsp_vm_ch_setup,
	.get_fw_hash = camrtc_hsp_vm_get_fw_hash,
};

static int camrtc_hsp_vm_send(struct camrtc_hsp *camhsp,
		int request, long *timeout)
{
	int response;
	unsigned long flags;

	spin_lock_irqsave(&camhsp->sendlock, flags);
	atomic_set(&camhsp->response, -1);
	response = mbox_send_message(camhsp->tx.chan, (void*)(unsigned long) request);
	spin_unlock_irqrestore(&camhsp->sendlock, flags);

	return response;
}

static void camrtc_hsp_vm_group_ring(struct camrtc_hsp *camhsp,
		u16 group)
{
	camrtc_hsp_vm_send_irqmsg(camhsp);
}

static void camrtc_hsp_vm_send_irqmsg(struct camrtc_hsp *camhsp)
{
	int irqmsg = CAMRTC_HSP_MSG(CAMRTC_HSP_IRQ, 1);
	int response;
	unsigned long flags;

	spin_lock_irqsave(&camhsp->sendlock, flags);
	response = mbox_send_message(camhsp->tx.chan, (void*)(unsigned long) irqmsg);
	spin_unlock_irqrestore(&camhsp->sendlock, flags);
}

static int camrtc_hsp_vm_sendrecv(struct camrtc_hsp *camhsp,
		int request, long *timeout)
{
	int response = camrtc_hsp_sendrecv(camhsp, request, timeout);

	if (response < 0)
		return response;

	if (CAMRTC_HSP_MSG_ID(request) != CAMRTC_HSP_MSG_ID(response)) {
		dev_err(&camhsp->dev,
			"request 0x%08x mismatch with response 0x%08x\n",
			request, response);
		return -EIO;
	}

	/* Return the 24-bit parameter only */
	return CAMRTC_HSP_MSG_PARAM(response);
}

static int camrtc_hsp_vm_sync(struct camrtc_hsp *camhsp, long *timeout)
{
	int response = camrtc_hsp_vm_hello(camhsp, timeout);

	if (response >= 0) {
		camhsp->cookie = response;
		response = camrtc_hsp_vm_protocol(camhsp, timeout);
	}

	return response;
}

static u32 camrtc_hsp_vm_cookie(void)
{
	u32 value = CAMRTC_HSP_MSG_PARAM(sched_clock() >> 5U);

	if (value == 0)
		value++;

	return value;
}

static int camrtc_hsp_vm_hello(struct camrtc_hsp *camhsp, long *timeout)
{
	int request = CAMRTC_HSP_MSG(CAMRTC_HSP_HELLO, camrtc_hsp_vm_cookie());
	int response = camrtc_hsp_send(camhsp, request, timeout);

	if (response < 0)
		return response;

	for (;;) {
		response = camrtc_hsp_recv(camhsp, request, timeout);

		/* Wait until we get the HELLO message we sent */
		if (response == request)
			break;

		/* ...or timeout */
		if (response < 0)
			break;
	}

	return response;
}

static int camrtc_hsp_vm_protocol(struct camrtc_hsp *camhsp, long *timeout)
{
	int request = CAMRTC_HSP_MSG(CAMRTC_HSP_PROTOCOL,
			RTCPU_DRIVER_SM6_VERSION);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_resume(struct camrtc_hsp *camhsp, long *timeout)
{
	int request = CAMRTC_HSP_MSG(CAMRTC_HSP_RESUME, camhsp->cookie);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_suspend(struct camrtc_hsp *camhsp, long *timeout)
{
	u32 request = CAMRTC_HSP_MSG(CAMRTC_HSP_SUSPEND, 0);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_bye(struct camrtc_hsp *camhsp, long *timeout)
{
	u32 request = CAMRTC_HSP_MSG(CAMRTC_HSP_BYE, 0);

	camhsp->cookie = 0U;

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_ch_setup(struct camrtc_hsp *camhsp,
		dma_addr_t iova, long *timeout)
{
	u32 request = CAMRTC_HSP_MSG(CAMRTC_HSP_CH_SETUP, iova >> 8);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_ping(struct camrtc_hsp *camhsp, u32 data,
		long *timeout)
{
	u32 request = CAMRTC_HSP_MSG(CAMRTC_HSP_PING, data);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_get_fw_hash(struct camrtc_hsp *camhsp, u32 index,
		long *timeout)
{
	u32 request = CAMRTC_HSP_MSG(CAMRTC_HSP_FW_HASH, index);

	return camrtc_hsp_vm_sendrecv(camhsp, request, timeout);
}

static int camrtc_hsp_vm_probe(struct camrtc_hsp *camhsp)
{
	struct device_node *np = camhsp->dev.parent->of_node;
	int err = -ENOTSUPP;
	const char *obtain = "";

	np = of_get_compatible_child(np, "nvidia,tegra-camrtc-hsp-vm");
	if (!of_device_is_available(np)) {
		of_node_put(np);
		dev_info(&camhsp->dev, "no hsp protocol \"%s\"\n",
			"nvidia,tegra-camrtc-hsp-vm");
		return -ENOTSUPP;
	}

	camhsp->dev.of_node = np;

	camhsp->rx.chan = mbox_request_channel_byname(&camhsp->rx.client, "vm-rx");
	if (IS_ERR(camhsp->rx.chan)) {
		err = PTR_ERR(camhsp->rx.chan);
		goto fail;
	}

	camhsp->tx.chan = mbox_request_channel_byname(&camhsp->tx.client, "vm-tx");
	if (IS_ERR(camhsp->tx.chan)) {
		err = PTR_ERR(camhsp->tx.chan);
		goto fail;
	}

	camhsp->op = &camrtc_hsp_vm_ops;
	dev_set_name(&camhsp->dev, "%s:%s",
		dev_name(camhsp->dev.parent), camhsp->dev.of_node->name);
	dev_dbg(&camhsp->dev, "probed\n");

	return 0;

fail:
	if (err != -EPROBE_DEFER) {
		dev_err(&camhsp->dev, "%s: failed to obtain %s: %d\n",
			np->name, obtain, err);
	}
	of_node_put(np);
	return err;
}

/* ---------------------------------------------------------------------- */
/* Public interface */

void camrtc_hsp_group_ring(struct camrtc_hsp *camhsp,
		u16 group)
{
	if (!WARN_ON(camhsp == NULL))
		camhsp->op->group_ring(camhsp, group);
}
EXPORT_SYMBOL(camrtc_hsp_group_ring);

/*
 * Synchronize the HSP
 */
int camrtc_hsp_sync(struct camrtc_hsp *camhsp)
{
	long timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);
	response = camhsp->op->sync(camhsp, &timeout);
	mutex_unlock(&camhsp->mutex);

	return response;
}
EXPORT_SYMBOL(camrtc_hsp_sync);

/*
 * Resume: resume the firmware
 */
int camrtc_hsp_resume(struct camrtc_hsp *camhsp)
{
	long timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);
	response = camhsp->op->resume(camhsp, &timeout);
	mutex_unlock(&camhsp->mutex);

	return response;
}
EXPORT_SYMBOL(camrtc_hsp_resume);

/*
 * Suspend: set firmware to idle.
 */
int camrtc_hsp_suspend(struct camrtc_hsp *camhsp)
{
	long timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);
	response = camhsp->op->suspend(camhsp, &timeout);
	mutex_unlock(&camhsp->mutex);

	if (response != 0)
		dev_info(&camhsp->dev, "PM_SUSPEND failed: 0x%08x\n",
			response);

	return response <= 0 ? response : -EIO;
}
EXPORT_SYMBOL(camrtc_hsp_suspend);

/*
 * Bye: tell firmware that VM mappings are going away
 */
int camrtc_hsp_bye(struct camrtc_hsp *camhsp)
{
	long timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);
	response = camhsp->op->bye(camhsp, &timeout);
	mutex_unlock(&camhsp->mutex);

	if (response != 0)
		dev_WARN(&camhsp->dev, "BYE failed: 0x%08x\n", response);

	return response;
}
EXPORT_SYMBOL(camrtc_hsp_bye);

int camrtc_hsp_ch_setup(struct camrtc_hsp *camhsp, dma_addr_t iova)
{
	long timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	if (iova >= BIT_ULL(32) || (iova & 0xffU) != 0) {
		dev_WARN(&camhsp->dev,
			"CH_SETUP invalid iova: 0x%08llx\n", iova);
		return -EINVAL;
	}

	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);
	response = camhsp->op->ch_setup(camhsp, iova, &timeout);
	mutex_unlock(&camhsp->mutex);

	if (response > 0)
		dev_dbg(&camhsp->dev, "CH_SETUP failed: 0x%08x\n", response);

	return response;
}
EXPORT_SYMBOL(camrtc_hsp_ch_setup);

int camrtc_hsp_ping(struct camrtc_hsp *camhsp, u32 data, long timeout)
{
	long left = timeout;
	int response;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	if (left == 0L)
		left = camhsp->timeout;

	mutex_lock(&camhsp->mutex);
	response = camhsp->op->ping(camhsp, data, &left);
	mutex_unlock(&camhsp->mutex);

	return response;
}
EXPORT_SYMBOL(camrtc_hsp_ping);

int camrtc_hsp_get_fw_hash(struct camrtc_hsp *camhsp,
		u8 hash[], size_t hash_size)
{
	int i;
	int ret = 0;
	long timeout;

	if (WARN_ON(camhsp == NULL))
		return -EINVAL;

	memset(hash, 0, hash_size);
	timeout = camhsp->timeout;
	mutex_lock(&camhsp->mutex);

	for (i = 0; i < hash_size; i++) {
		int value = camhsp->op->get_fw_hash(camhsp, i, &timeout);

		if (value < 0 || value > 255) {
			dev_info(&camhsp->dev,
				"FW_HASH failed: 0x%08x\n", value);
			ret = value < 0 ? value : -EIO;
			goto fail;
		}

		hash[i] = value;
	}

fail:
	mutex_unlock(&camhsp->mutex);

	return ret;
}
EXPORT_SYMBOL(camrtc_hsp_get_fw_hash);

static const struct device_type camrtc_hsp_combo_dev_type = {
	.name	= "camrtc-hsp-protocol",
};

static void camrtc_hsp_combo_dev_release(struct device *dev)
{
	struct camrtc_hsp *camhsp = container_of(dev, struct camrtc_hsp, dev);

	if (!IS_ERR_OR_NULL(camhsp->rx.chan))
		mbox_free_channel(camhsp->rx.chan);
	if (!IS_ERR_OR_NULL(camhsp->tx.chan))
		mbox_free_channel(camhsp->tx.chan);
	if (!IS_ERR_OR_NULL(camhsp->ivc_tx.chan))
		mbox_free_channel(camhsp->ivc_tx.chan);
	if (!IS_ERR_OR_NULL(camhsp->ivc_rx.chan))
		mbox_free_channel(camhsp->ivc_rx.chan);

	of_node_put(dev->of_node);
	kfree(camhsp);
}

static int camrtc_hsp_probe(struct camrtc_hsp *camhsp)
{
	int ret;

	ret = camrtc_hsp_vm_probe(camhsp);
	if (ret != -ENOTSUPP)
		return ret;

	ret = camrtc_hsp_cmd_probe(camhsp);
	if (ret != -ENOTSUPP)
		return ret;

	return -ENODEV;
}

struct camrtc_hsp *camrtc_hsp_create(
	struct device *dev,
	void (*group_notify)(struct device *dev, u16 group),
	long cmd_timeout)
{
	struct camrtc_hsp *camhsp;
	int ret = -EINVAL;

	camhsp = kzalloc(sizeof(*camhsp), GFP_KERNEL);
	if (camhsp == NULL)
		return ERR_PTR(-ENOMEM);

	camhsp->dev.parent = dev;
	camhsp->group_notify = group_notify;
	camhsp->timeout = cmd_timeout;
	mutex_init(&camhsp->mutex);
	spin_lock_init(&camhsp->sendlock);
	init_waitqueue_head(&camhsp->response_waitq);
	init_completion(&camhsp->emptied);
	atomic_set(&camhsp->response, -1);

	camhsp->dev.type = &camrtc_hsp_combo_dev_type;
	camhsp->dev.release = camrtc_hsp_combo_dev_release;
	device_initialize(&camhsp->dev);

	dev_set_name(&camhsp->dev, "%s:%s", dev_name(dev), "hsp");

	pm_runtime_no_callbacks(&camhsp->dev);
	pm_runtime_enable(&camhsp->dev);

	camhsp->tx.client.tx_block = false;
	camhsp->rx.client.rx_callback = camrtc_hsp_rx_full_notify;
	camhsp->tx.client.tx_done = camrtc_hsp_tx_empty_notify;
	camhsp->rx.client.dev = camhsp->tx.client.dev = &(camhsp->dev);

	ret = camrtc_hsp_probe(camhsp);
	if (ret < 0)
		goto fail;

	ret = device_add(&camhsp->dev);
	if (ret < 0)
		goto fail;

	dev_set_drvdata(&camhsp->dev, camhsp);

	return camhsp;

fail:
	camrtc_hsp_free(camhsp);
	return ERR_PTR(ret);
}
EXPORT_SYMBOL(camrtc_hsp_create);

void camrtc_hsp_free(struct camrtc_hsp *camhsp)
{
	if (IS_ERR_OR_NULL(camhsp))
		return;

	pm_runtime_disable(&camhsp->dev);

	if (dev_get_drvdata(&camhsp->dev) != NULL)
		device_unregister(&camhsp->dev);
	else
		put_device(&camhsp->dev);
}
EXPORT_SYMBOL(camrtc_hsp_free);
