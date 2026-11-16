#ifndef SPECTRULENPOR_SENSORS_H
#define SPECTRULENPOR_SENSORS_H

#include "esp_err.h"
#include "config.h"

#define AS7265x_TAG "AS7265x"

typedef struct {
    uint16_t uv_raw;   /* Legacy wire name: channel A, 410 nm, not a UV index. */
    uint16_t ir_raw;   /* Channel W, 940 nm. */
    bool     available;
} as7265x_reading_t;

/* Initialize I2C1 and probe the AS7265x chip. Returns ESP_OK on success. */
esp_err_t sensors_init(void);

/* Read UV + IR channel values into out. Returns ESP_OK on success. */
esp_err_t sensors_read_uv_ir(as7265x_reading_t *out);
bool sensors_available(void);

/* Last cached reading. */
extern as7265x_reading_t g_last_sensor_reading;

#endif /* SPECTRULENPOR_SENSORS_H */
