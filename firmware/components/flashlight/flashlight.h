#ifndef SPECTRULENPOR_FLASHLIGHT_H
#define SPECTRULENPOR_FLASHLIGHT_H

#include "config.h"
#include "esp_err.h"

esp_err_t flashlight_init(void);
esp_err_t flashlight_set(bool on);
bool flashlight_is_on(void);

#endif /* SPECTRULENPOR_FLASHLIGHT_H */
