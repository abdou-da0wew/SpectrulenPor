#ifndef SPECTRULENPOR_SENSORS_H
#define SPECTRULENPOR_SENSORS_H

#include "driver/i2c.h"
#include "config.h"

#define AS7265x_TAG "AS7265x"

typedef struct {
    uint16_t uv_raw;   /* 0..65535 raw channel value          */
    uint16_t ir_raw;   /* 0..65535 raw channel value          */
    bool     available;
} as7265x_reading_t;

/* Initialize I2C1 and probe the AS7265x chip. Returns ESP_OK on success. */
esp_err_t sensors_init(void);

/* Read UV + IR channel values into out. Returns ESP_OK on success. */
esp_err_t sensors_read_uv_ir(as7265x_reading_t *out);

/* Last cached reading. */
extern as7265x_reading_t g_last_sensor_reading;

#endif /* SPECTRULENPOR_SENSORS_H */
