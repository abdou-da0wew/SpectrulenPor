#ifndef SPECTRULENPOR_SENSORS_H
#define SPECTRULENPOR_SENSORS_H

#include "esp_err.h"
#include "config.h"

#define AS7265X_TAG "AS7265x"
#define AS7265X_CHANNEL_COUNT 18U
#define AS7265X_DEVICE_TEMPERATURE_COUNT 3U

typedef struct {
    /* Raw ADC counts ordered by ascending wavelength: 410 nm through 940 nm. */
    uint16_t raw[AS7265X_CHANNEL_COUNT];
    /* Die temperatures indexed AS72653, AS72652, AS72651, in degrees Celsius. */
    int8_t temperature_c[AS7265X_DEVICE_TEMPERATURE_COUNT];
    bool available;
} as7265x_reading_t;

/* Initialize I2C1 and probe the full three-device AS7265x chipset. */
esp_err_t sensors_init(void);

/* Read all 18 raw spectral channels and the three sensor-die temperatures. */
esp_err_t sensors_read_spectrum(as7265x_reading_t *out);
bool sensors_available(void);

/* Last complete spectral reading. */
extern as7265x_reading_t g_last_sensor_reading;

#endif /* SPECTRULENPOR_SENSORS_H */
