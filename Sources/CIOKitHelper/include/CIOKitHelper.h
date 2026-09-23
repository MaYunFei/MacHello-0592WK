#ifndef CIOKIT_HELPER_H
#define CIOKIT_HELPER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool dell_camera_is_connected(void);
int dell_camera_set_mode(uint8_t mode);

#ifdef __cplusplus
}
#endif

#endif /* CIOKIT_HELPER_H */
