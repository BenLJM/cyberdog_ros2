#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include "camrtc-capture.h"
#include "camrtc-capture-messages.h"
int main(void){
#define P(s) printf("%-40s %4zu\n", #s, sizeof(struct s))
    P(capture_descriptor);
    P(capture_channel_config);
    P(capture_channel_isp_config);
    P(isp_capture_descriptor);
    P(CAPTURE_CONTROL_MSG);
    P(CAPTURE_MSG);
    printf("%-40s %4zu\n","offsetof capture_descriptor.status",
        offsetof(struct capture_descriptor, status));
    printf("%-40s %4zu\n","offsetof capture_descriptor.ch_cfg",
        offsetof(struct capture_descriptor, ch_cfg));
    return 0;
}
