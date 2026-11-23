#include <limits.h>
#include <string.h>
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sensors.h"
#include "config.h"
#include "as7265x_registers.h"

static const char *TAG = AS7265X_TAG;

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_device;
static bool s_available;
as7265x_reading_t g_last_sensor_reading;

bool sensors_available(void) { return s_available; }

static esp_err_t physical_write(uint8_t reg, uint8_t value)
{
    const uint8_t data[] = {reg, value};
    return i2c_master_transmit(s_device, data, sizeof(data), SENSOR_I2C_TIMEOUT_MS);
}

static esp_err_t physical_read(uint8_t reg, uint8_t *value)
{
    return i2c_master_transmit_receive(s_device, &reg, sizeof(reg), value,
                                        sizeof(*value), SENSOR_I2C_TIMEOUT_MS);
}

static esp_err_t wait_mailbox(uint8_t mask, bool set)
{
    int64_t deadline = esp_timer_get_time() + SENSOR_VIRTUAL_TIMEOUT_MS * 1000LL;
    while (esp_timer_get_time() < deadline) {
        uint8_t status;
        esp_err_t err = physical_read(AS7265X_STATUS, &status);
        if (err != ESP_OK) {
            return err;
        }
        if (((status & mask) != 0) == set) {
            return ESP_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(SENSOR_POLL_INTERVAL_MS));
    }
    return ESP_ERR_TIMEOUT;
}

static esp_err_t virtual_write(uint8_t reg, uint8_t value)
{
    esp_err_t err = wait_mailbox(AS7265X_TX_VALID, false);
    if (err == ESP_OK) {
        err = physical_write(AS7265X_WRITE, reg | AS7265X_VIRTUAL_WRITE_FLAG);
    }
    if (err == ESP_OK) {
        err = wait_mailbox(AS7265X_TX_VALID, false);
    }
    if (err == ESP_OK) {
        err = physical_write(AS7265X_WRITE, value);
    }
    return err;
}

static esp_err_t virtual_read(uint8_t reg, uint8_t *value)
{
    uint8_t status;
    esp_err_t err = physical_read(AS7265X_STATUS, &status);
    if (err == ESP_OK && (status & AS7265X_RX_VALID) != 0) {
        uint8_t discarded;
        err = physical_read(AS7265X_READ, &discarded);
    }
    if (err == ESP_OK) {
        err = wait_mailbox(AS7265X_TX_VALID, false);
    }
    if (err == ESP_OK) {
        err = physical_write(AS7265X_WRITE, reg);
    }
    if (err == ESP_OK) {
        err = wait_mailbox(AS7265X_RX_VALID, true);
    }
    if (err == ESP_OK) {
        err = physical_read(AS7265X_READ, value);
    }
    return err;
}

static esp_err_t select_device(uint8_t device)
{
    return virtual_write(AS7265X_DEVICE_SELECT, device);
}

static esp_err_t read_selected_channel(uint8_t reg, uint16_t *out)
{
    uint8_t high, low;
    esp_err_t err = virtual_read(reg, &high);
    if (err == ESP_OK) {
        err = virtual_read(reg + 1U, &low);
    }
    if (err == ESP_OK) {
        *out = (uint16_t)(((uint16_t)high << 8U) | low);
    }
    return err;
}

static esp_err_t read_selected_temperature(int8_t *out)
{
    uint8_t raw;
    esp_err_t err = virtual_read(AS7265X_TEMPERATURE, &raw);
    if (err == ESP_OK) {
        /* The datasheet reserves -128 as a temperature-read error sentinel. */
        *out = raw == 0x80U ? INT8_MIN : (int8_t)raw;
    }
    return err;
}

esp_err_t sensors_init(void)
{
    i2c_master_bus_config_t bus_config = {
        .i2c_port = AS7265x_I2C_NUM,
        .sda_io_num = PIN_AS72655_SDA,
        .scl_io_num = PIN_AS72655_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    esp_err_t err = i2c_new_master_bus(&bus_config, &s_bus);
    if (err != ESP_OK) {
        return err;
    }
    err = i2c_master_probe(s_bus, AS7265x_I2C_ADDR, SENSOR_I2C_TIMEOUT_MS);
    if (err != ESP_OK) {
        i2c_del_master_bus(s_bus);
        s_bus = NULL;
        ESP_LOGW(TAG, "operation=sensor.probe outcome=unavailable code=SENSOR_NOT_FOUND");
        return err;
    }
    i2c_device_config_t device_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AS7265x_I2C_ADDR,
        .scl_speed_hz = AS7265x_I2C_FREQ,
    };
    err = i2c_master_bus_add_device(s_bus, &device_config, &s_device);
    uint8_t devices = 0;
    if (err == ESP_OK) {
        err = virtual_read(AS7265X_DEVICE_SELECT, &devices);
    }
    if (err == ESP_OK && (devices & AS7265X_SLAVES_PRESENT) != AS7265X_SLAVES_PRESENT) {
        err = ESP_ERR_NOT_FOUND;
    }
    if (err == ESP_OK) {
        err = virtual_write(AS7265X_INTEGRATION, SENSOR_INTEGRATION_CYCLES);
    }
    if (err == ESP_OK) {
        err = virtual_write(AS7265X_CONFIG,
                            AS7265X_GAIN_64X | AS7265X_ALL_CHANNELS_CONTINUOUS);
    }
    if (err != ESP_OK) {
        if (s_device != NULL) {
            i2c_master_bus_rm_device(s_device);
            s_device = NULL;
        }
        i2c_del_master_bus(s_bus);
        s_bus = NULL;
        return err;
    }
    s_available = true;
    ESP_LOGI(TAG, "operation=sensor.init channels=18 devices=3 gain=64x outcome=success");
    return err;
}

esp_err_t sensors_read_spectrum(as7265x_reading_t *out)
{
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(out, 0, sizeof(*out));
    if (!s_available) {
        return ESP_ERR_NOT_FOUND;
    }

    uint8_t config;
    esp_err_t err = virtual_read(AS7265X_CONFIG, &config);
    if (err != ESP_OK) {
        return err;
    }
    if ((config & AS7265X_DATA_READY) == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    /*
     * Virtual RAW registers 0x08..0x13 are shared across the three dies.
     * Each DEV_SEL chooses whether those six pairs represent A..F, G..L,
     * or R..W. Store in ascending optical wavelength order for the host.
     */
    static const uint8_t devices[AS7265X_DEVICE_TEMPERATURE_COUNT] = {
        AS7265X_DEVICE_AS72653,
        AS7265X_DEVICE_AS72652,
        AS7265X_DEVICE_AS72651,
    };
    static const uint8_t channel_indices[AS7265X_DEVICE_TEMPERATURE_COUNT]
                                         [AS7265X_RAW_CHANNELS_PER_DEVICE] = {
        {0, 1, 2, 3, 4, 5},       /* A..F: 410..535 nm */
        {6, 7, 9, 11, 16, 17},    /* G,H,I,J,K,L */
        {8, 10, 12, 13, 14, 15},  /* R,S,T,U,V,W */
    };

    as7265x_reading_t reading = {0};
    for (size_t device_index = 0;
         device_index < AS7265X_DEVICE_TEMPERATURE_COUNT && err == ESP_OK;
         ++device_index) {
        err = select_device(devices[device_index]);
        for (size_t channel = 0;
             channel < AS7265X_RAW_CHANNELS_PER_DEVICE && err == ESP_OK;
             ++channel) {
            const uint8_t reg = (uint8_t)(AS7265X_RAW_CHANNEL_BASE +
                channel * AS7265X_RAW_CHANNEL_STRIDE);
            const uint8_t destination = channel_indices[device_index][channel];
            err = read_selected_channel(reg, &reading.raw[destination]);
        }
        if (err == ESP_OK) {
            err = read_selected_temperature(&reading.temperature_c[device_index]);
        }
    }
    if (err != ESP_OK) {
        return err;
    }

    reading.available = true;
    *out = reading;
    g_last_sensor_reading = reading;
    return ESP_OK;
}
