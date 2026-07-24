/*
 * include/uapi/linux/nvmap.h
 *
 * structure declarations for nvmem and nvmap user-space ioctls
 *
 * Copyright (c) 2009-2022, NVIDIA CORPORATION. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 */

#include <linux/ioctl.h>
#include <linux/types.h>

#ifndef __UAPI_LINUX_NVMAP_H
#define __UAPI_LINUX_NVMAP_H

/*
 * DOC: NvMap Userspace API
 *
 * create a client by opening /dev/nvmap
 * most operations handled via following ioctls
 *
 */
enum {
	NVMAP_HANDLE_PARAM_SIZE = 1,
	NVMAP_HANDLE_PARAM_ALIGNMENT,
	NVMAP_HANDLE_PARAM_BASE,
	NVMAP_HANDLE_PARAM_HEAP,
	NVMAP_HANDLE_PARAM_KIND,
	NVMAP_HANDLE_PARAM_COMPR, /* ignored, to be removed */
};

enum {
	NVMAP_CACHE_OP_WB = 0,
	NVMAP_CACHE_OP_INV,
	NVMAP_CACHE_OP_WB_INV,
};

enum {
	NVMAP_PAGES_UNRESERVE = 0,
	NVMAP_PAGES_RESERVE,
	NVMAP_INSERT_PAGES_ON_UNRESERVE,
	NVMAP_PAGES_PROT_AND_CLEAN,
};

#define NVMAP_ELEM_SIZE_U64 (1 << 31)

struct nvmap_create_handle {
	union {
		struct {
			union {
				/* size will be overwritten */
				__u32 size;	/* CreateHandle */
				__s32 fd;	/* DmaBufFd or FromFd */
			};
			__u32 handle;		/* returns nvmap handle */
		};
		struct {
			/* one is input parameter, and other is output parameter
			 * since its a union please note that input parameter
			 * will be overwritten once ioctl returns
			 */
			union {
				__u64 ivm_id;	 /* CreateHandle from ivm*/
				__u32 ivm_handle;/* Get ivm_id from handle */
			};
		};
		struct {
			union {
				/* size64 will be overwritten */
				__u64 size64; /* CreateHandle */
				__u32 handle64; /* returns nvmap handle */
			};
		};
	};
};

struct nvmap_create_handle_from_va {
	__u64 va;		/* FromVA*/
	__u32 size;		/* non-zero for partial memory VMA. zero for end of VMA */
	__u32 flags;		/* wb/wc/uc/iwb, tag etc. */
	union {
		__u32 handle;		/* returns nvmap handle */
		__u64 size64;		/* used when size is 0 */
	};
};

struct nvmap_gup_test {
	__u64 va;		/* FromVA*/
	__u32 handle;		/* returns nvmap handle */
	__u32 result;		/* result=1 for pass, result=-err for failure */
};

struct nvmap_alloc_handle {
	__u32 handle;		/* nvmap handle */
	__u32 heap_mask;	/* heaps to allocate from */
	__u32 flags;		/* wb/wc/uc/iwb etc. */
	__u32 align;		/* min alignment necessary */
};

struct nvmap_alloc_ivm_handle {
	__u32 handle;		/* nvmap handle */
	__u32 heap_mask;	/* heaps to allocate from */
	__u32 flags;		/* wb/wc/uc/iwb etc. */
	__u32 align;		/* min alignment necessary */
	__u32 peer;		/* peer with whom handle must be shared. Used
				 *  only for NVMAP_HEAP_CARVEOUT_IVM
				 */
};

struct nvmap_rw_handle {
	__u64 addr;		/* user pointer*/
	__u32 handle;		/* nvmap handle */
	__u64 offset;		/* offset into hmem */
	__u64 elem_size;	/* individual atom size */
	__u64 hmem_stride;	/* delta in bytes between atoms in hmem */
	__u64 user_stride;	/* delta in bytes between atoms in user */
	__u64 count;		/* number of atoms to copy */
};

#ifdef __KERNEL__
/*
 * R32 (JetPack4) ABI compat.  The factory nvargus-daemon/libargus in the JP4
 * chroot is a 64-bit (aarch64) binary compiled against R32 headers, where
 * struct nvmap_rw_handle is 32 bytes: an 8-byte 'unsigned long addr' followed
 * by six __u32 fields.  R35 widened the trailing fields to __u64 (56 bytes),
 * so _IOW() encodes a different size and the R32 WRITE/READ ioctl numbers no
 * longer match the R35 ones -> the driver returns -ENOTTY.  This re-creates the
 * exact R32 layout so the R35 driver accepts the legacy ioctls.  It is guarded
 * by __KERNEL__ only (NOT CONFIG_COMPAT): the caller is a 64-bit task, so it
 * reaches the native unlocked_ioctl path, not compat_ioctl.
 */
struct nvmap_rw_handle_r32 {
	__u64 addr;		/* user pointer (R32 'unsigned long', 8B aarch64) */
	__u32 handle;		/* nvmap handle */
	__u32 offset;		/* offset into hmem */
	__u32 elem_size;	/* individual atom size */
	__u32 hmem_stride;	/* delta in bytes between atoms in hmem */
	__u32 user_stride;	/* delta in bytes between atoms in user */
	__u32 count;		/* number of atoms to copy */
};
#endif /* __KERNEL__ */

#ifdef __KERNEL__
/*
 * R32 (JetPack4) ABI compat for the removed MMAP / PIN_MULT / UNPIN_MULT ioctls.
 * R35 deleted these three ioctls outright (both the structs and the numbers).
 * The factory aarch64 nvargus/libargus (built against R32 headers) may still
 * probe them.  These replicas reproduce the *exact* R32 struct sizes so the
 * re-added ioctl numbers equal the ones the userspace emits
 * (MMAP=0xc0184e05, PIN_MULT=0xc0184e0a, UNPIN_MULT=0x40184e0b — verified).
 *
 * IMPORTANT: unlike WRITE/READ (which are fully functional and whose only R32
 * delta was struct size), MMAP/PIN were ALREADY deprecated no-ops on the
 * shipped R32 CyberDog kernel (returned -ENOTTY), and cannot be safely bridged
 * on R35 (see NOTES.md).  The re-added dispatch cases therefore reproduce the
 * exact R32 behaviour (-ENOTTY) — they are a named-deprecation compat surface,
 * NOT a functional map/pin.  __KERNEL__ only (64-bit caller -> native path).
 */
struct nvmap_map_caller_r32 {
	__u32 handle;		/* nvmap handle */
	__u32 offset;		/* offset into hmem; page-aligned */
	__u32 length;		/* number of bytes to map */
	__u32 flags;		/* maps as wb/iwb etc. */
	__u64 addr;		/* R32 'unsigned long', 8B on aarch64 */
};

struct nvmap_pin_handle_r32 {
	__u64 handles;		/* R32 '__u32 *handles' — 8B pointer on aarch64 */
	__u64 addr;		/* R32 'unsigned long *addr' — 8B pointer */
	__u32 count;		/* number of entries in handles */
};
#endif /* __KERNEL__ */

#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
struct nvmap_rw_handle_32 {
	__u32 addr;		/* user pointer */
	__u32 handle;		/* nvmap handle */
	__u32 offset;		/* offset into hmem */
	__u32 elem_size;	/* individual atom size */
	__u32 hmem_stride;	/* delta in bytes between atoms in hmem */
	__u32 user_stride;	/* delta in bytes between atoms in user */
	__u32 count;		/* number of atoms to copy */
};
#endif /* CONFIG_COMPAT */
#endif /* __KERNEL__ */

struct nvmap_handle_param {
	__u32 handle;		/* nvmap handle */
	__u32 param;		/* size/align/base/heap etc. */
	unsigned long result;	/* returns requested info*/
};

#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
struct nvmap_handle_param_32 {
	__u32 handle;		/* nvmap handle */
	__u32 param;		/* size/align/base/heap etc. */
	__u32 result;		/* returns requested info*/
};
#endif /* CONFIG_COMPAT */
#endif /* __KERNEL__ */

struct nvmap_cache_op {
	unsigned long addr;	/* user pointer*/
	__u32 handle;		/* nvmap handle */
	__u32 len;		/* bytes to flush */
	__s32 op;		/* wb/wb_inv/inv */
};

struct nvmap_cache_op_64 {
	unsigned long addr;	/* user pointer*/
	__u32 handle;		/* nvmap handle */
	__u64 len;		/* bytes to flush */
	__s32 op;		/* wb/wb_inv/inv */
};

#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
struct nvmap_cache_op_32 {
	__u32 addr;		/* user pointer*/
	__u32 handle;		/* nvmap handle */
	__u32 len;		/* bytes to flush */
	__s32 op;		/* wb/wb_inv/inv */
};
#endif /* CONFIG_COMPAT */
#endif /* __KERNEL__ */

struct nvmap_cache_op_list {
	__u64 handles;		/* Ptr to u32 type array, holding handles */
	__u64 offsets;		/* Ptr to u32 type array, holding offsets
				 * into handle mem */
	__u64 sizes;		/* Ptr to u32 type array, holindg sizes of memory
				 * regions within each handle */
	__u32 nr;		/* Number of handles */
	__s32 op;		/* wb/wb_inv/inv */
};

struct nvmap_debugfs_handles_header {
	__u8 version;
};

struct nvmap_debugfs_handles_entry {
	__u64 base;
	__u64 size;
	__u32 flags;
	__u32 share_count;
	__u64 mapped_size;
};

struct nvmap_set_tag_label {
	__u32 tag;
	__u32 len;		/* in: label length
				   out: number of characters copied */
	__u64 addr;		/* in: pointer to label or NULL to remove */
};

struct nvmap_available_heaps {
	__u64 heaps;		/* heaps bitmask */
};

struct nvmap_heap_size {
	__u32 heap;
	__u64 size;
};

struct nvmap_sciipc_map {
	__u64 auth_token;    /* AuthToken */
	__u32 flags;       /* Exporter permission flags */
	__u32 sci_ipc_id;  /* FromImportId */
	__u32 handle;      /* Nvmap handle */
};

struct nvmap_handle_parameters {
    __u8 contig;
    __u32 import_id;
    __u32 handle;
    __u32 heap_number;
    __u32 access_flags;
    __u64 heap;
    __u64 align;
    __u64 coherency;
    __u64 size;
    __u64 offset;
};

#ifdef __KERNEL__
/*
 * R32 (JetPack4) ABI compat for GET_HANDLE_PARAMETERS.  R35 appended a trailing
 * __u64 offset, growing the struct 56 -> 64 bytes; the first 56 bytes are
 * byte-identical to R32.  The R32 userspace passes a 56-byte buffer, so the
 * _IOR() size (and hence the ioctl number) differs.  __KERNEL__ only, not
 * CONFIG_COMPAT (64-bit caller, native ioctl path).
 */
struct nvmap_handle_parameters_r32 {
    __u8 contig;
    __u32 import_id;
    __u32 handle;
    __u32 heap_number;
    __u32 access_flags;
    __u64 heap;
    __u64 align;
    __u64 coherency;
    __u64 size;
};
#endif /* __KERNEL__ */

/**
 * Struct used while querying heap parameters
 */
struct nvmap_query_heap_params {
	__u32 heap_mask;
	__u32 flags;
	__u8 contig;
	__u64 total;
	__u64 free;
	__u64 largest_free_block;
};

/**
 * Struct used while duplicating memory handle
 */
struct nvmap_duplicate_handle {
	__u32 handle;
	__u32 access_flags;
	__u32 dup_handle;
};

#define NVMAP_IOC_MAGIC 'N'

/* Creates a new memory handle. On input, the argument is the size of the new
 * handle; on return, the argument is the name of the new handle
 */
#define NVMAP_IOC_CREATE  _IOWR(NVMAP_IOC_MAGIC, 0, struct nvmap_create_handle)
#define NVMAP_IOC_CREATE_64 \
	_IOWR(NVMAP_IOC_MAGIC, 1, struct nvmap_create_handle)
#define NVMAP_IOC_FROM_ID _IOWR(NVMAP_IOC_MAGIC, 2, struct nvmap_create_handle)

/* Actually allocates memory for the specified handle */
#define NVMAP_IOC_ALLOC    _IOW(NVMAP_IOC_MAGIC, 3, struct nvmap_alloc_handle)

/* Frees a memory handle, unpinning any pinned pages and unmapping any mappings
 */
#define NVMAP_IOC_FREE       _IO(NVMAP_IOC_MAGIC, 4)

#ifdef __KERNEL__
/* R32 (JP4) compat: legacy NVMAP_IOC_MMAP (nr 5), removed in R35. Re-added as a
 * named -ENOTTY deprecation only (no functional map — see NOTES.md). */
#define NVMAP_IOC_MMAP_R32 \
	_IOWR(NVMAP_IOC_MAGIC, 5, struct nvmap_map_caller_r32)
#endif /* __KERNEL__ */

/* Reads/writes data (possibly strided) from a user-provided buffer into the
 * hmem at the specified offset */
#define NVMAP_IOC_WRITE      _IOW(NVMAP_IOC_MAGIC, 6, struct nvmap_rw_handle)
#define NVMAP_IOC_READ       _IOW(NVMAP_IOC_MAGIC, 7, struct nvmap_rw_handle)
#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
#define NVMAP_IOC_WRITE_32   _IOW(NVMAP_IOC_MAGIC, 6, struct nvmap_rw_handle_32)
#define NVMAP_IOC_READ_32    _IOW(NVMAP_IOC_MAGIC, 7, struct nvmap_rw_handle_32)
#endif /* CONFIG_COMPAT */
/* R32 (JP4) native WRITE/READ: _IOW('N', 6/7, 32-byte struct). Matches the
 * ioctl numbers the factory aarch64 nvargus/libargus emit. */
#define NVMAP_IOC_WRITE_R32  _IOW(NVMAP_IOC_MAGIC, 6, struct nvmap_rw_handle_r32)
#define NVMAP_IOC_READ_R32   _IOW(NVMAP_IOC_MAGIC, 7, struct nvmap_rw_handle_r32)
#endif /* __KERNEL__ */

#define NVMAP_IOC_PARAM _IOWR(NVMAP_IOC_MAGIC, 8, struct nvmap_handle_param)
#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
#define NVMAP_IOC_PARAM_32 _IOWR(NVMAP_IOC_MAGIC, 8, struct nvmap_handle_param_32)
#endif /* CONFIG_COMPAT */
/* R32 (JP4) compat: legacy PIN_MULT (nr 10) / UNPIN_MULT (nr 11), removed in
 * R35. Re-added as a named -ENOTTY deprecation only (no functional pin — R35
 * has no static IOVA, see NOTES.md). */
#define NVMAP_IOC_PIN_MULT_R32 \
	_IOWR(NVMAP_IOC_MAGIC, 10, struct nvmap_pin_handle_r32)
#define NVMAP_IOC_UNPIN_MULT_R32 \
	_IOW(NVMAP_IOC_MAGIC, 11, struct nvmap_pin_handle_r32)
#endif /* __KERNEL__ */

#define NVMAP_IOC_CACHE      _IOW(NVMAP_IOC_MAGIC, 12, struct nvmap_cache_op)
#define NVMAP_IOC_CACHE_64   _IOW(NVMAP_IOC_MAGIC, 12, struct nvmap_cache_op_64)
#ifdef __KERNEL__
#ifdef CONFIG_COMPAT
#define NVMAP_IOC_CACHE_32  _IOW(NVMAP_IOC_MAGIC, 12, struct nvmap_cache_op_32)
#endif /* CONFIG_COMPAT */
#endif /* __KERNEL__ */

/* Returns a global ID usable to allow a remote process to create a handle
 * reference to the same handle */
#define NVMAP_IOC_GET_ID  _IOWR(NVMAP_IOC_MAGIC, 13, struct nvmap_create_handle)

/* Returns a file id that allows a remote process to create a handle
 * reference to the same handle */
#define NVMAP_IOC_GET_FD  _IOWR(NVMAP_IOC_MAGIC, 15, struct nvmap_create_handle)

/* Create a new memory handle from file id passed */
#define NVMAP_IOC_FROM_FD _IOWR(NVMAP_IOC_MAGIC, 16, struct nvmap_create_handle)

/* Perform cache maintenance on a list of handles. */
#define NVMAP_IOC_CACHE_LIST _IOW(NVMAP_IOC_MAGIC, 17,	\
				  struct nvmap_cache_op_list)

#define NVMAP_IOC_FROM_IVC_ID _IOWR(NVMAP_IOC_MAGIC, 19, struct nvmap_create_handle)
#define NVMAP_IOC_GET_IVC_ID _IOWR(NVMAP_IOC_MAGIC, 20, struct nvmap_create_handle)
#define NVMAP_IOC_GET_IVM_HEAPS _IOR(NVMAP_IOC_MAGIC, 21, unsigned int)

/* Create a new memory handle from VA passed */
#define NVMAP_IOC_FROM_VA _IOWR(NVMAP_IOC_MAGIC, 22, struct nvmap_create_handle_from_va)

#define NVMAP_IOC_GUP_TEST _IOWR(NVMAP_IOC_MAGIC, 23, struct nvmap_gup_test)

/* Define a label for allocation tag */
#define NVMAP_IOC_SET_TAG_LABEL	_IOW(NVMAP_IOC_MAGIC, 24, struct nvmap_set_tag_label)

#define NVMAP_IOC_GET_AVAILABLE_HEAPS \
	_IOR(NVMAP_IOC_MAGIC, 25, struct nvmap_available_heaps)

#define NVMAP_IOC_GET_HEAP_SIZE \
	_IOR(NVMAP_IOC_MAGIC, 26, struct nvmap_heap_size)

#define NVMAP_IOC_PARAMETERS \
	_IOR(NVMAP_IOC_MAGIC, 27, struct nvmap_handle_parameters)
#ifdef __KERNEL__
/* R32 (JP4) GET_HANDLE_PARAMETERS: _IOR('N', 27, 56-byte struct). */
#define NVMAP_IOC_PARAMETERS_R32 \
	_IOR(NVMAP_IOC_MAGIC, 27, struct nvmap_handle_parameters_r32)
#endif /* __KERNEL__ */

/* START of T124 IOCTLS */
/* Actually allocates memory from IVM heaps */
#define NVMAP_IOC_ALLOC_IVM _IOW(NVMAP_IOC_MAGIC, 101, struct nvmap_alloc_ivm_handle)

/* Allocate seperate memory for VPR */
#define NVMAP_IOC_VPR_FLOOR_SIZE _IOW(NVMAP_IOC_MAGIC, 102, __u32)

/* Get SCI_IPC_ID tied up with nvmap_handle */
#define NVMAP_IOC_GET_SCIIPCID _IOR(NVMAP_IOC_MAGIC, 103, \
		struct nvmap_sciipc_map)

/* Get Nvmap handle from SCI_IPC_ID */
#define NVMAP_IOC_HANDLE_FROM_SCIIPCID _IOR(NVMAP_IOC_MAGIC, 104, \
		struct nvmap_sciipc_map)

/* Get heap parameters such as total and frre size */
#define NVMAP_IOC_QUERY_HEAP_PARAMS _IOR(NVMAP_IOC_MAGIC, 105, \
		struct nvmap_query_heap_params)

/* Duplicate NvRmMemHandle with same/reduced permission */
#define NVMAP_IOC_DUP_HANDLE _IOWR(NVMAP_IOC_MAGIC, 106, \
		struct nvmap_duplicate_handle)

#define NVMAP_IOC_MAXNR (_IOC_NR(NVMAP_IOC_DUP_HANDLE))

#endif /* __UAPI_LINUX_NVMAP_H */
