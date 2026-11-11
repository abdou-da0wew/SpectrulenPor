#include "esp_log.h"
#include "driver/i2c.h"
#include "sensors.h"
#include "config.h"

static const char *TAG = AS7265x_TAG;

/* AS7265x register map (typical; adjust to exact datasheet revision) */
#define REG_DEVICE_ID   0x00
#define REG_CONTROL     0x01
#define REG_CH_UV_DATA  0x10   /* UV channel data (2 bytes, big-endian) */
#define REG_CH_IR_DATA  0x12   /* IR channel data (2 bytes, big-endian) */
#define REG_ENABLE_UV   0x20
#define REG_ENABLE_IR   0x21

#define CHIP_ID_EXPECTED 0x55   /* placeholder — verify per variant     */

static as7265x_reading_t g_reading = {0, 0, false};
as7265x_reading_t g_last_sensor_reading = {0, 0, false};

/* -----------------------------------------------------------------------
 *  Low-level I2C helpers (I2C bus 1 = GPIO13 SDA / GPIO14 SCL)
 * --------------------------------------------------------------------- */
static esp_err_t i2c_write_reg(uint8_t reg, uint8_t val)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (AS7265x_I2C_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg, true);
    i2c_master_write_byte(cmd, val, true);
    i2c_master_stop(cmd);
    esp_err_t ret = i2c_master_cmd_begin(AS7265x_I2C_NUM, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);
    return ret;
}

static esp_err_t i2c_read_regs(uint8_t reg, uint8_t *buf, size_t len)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (AS7265x_I2C_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg, true);
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (AS7265x_I2C_ADDR << 1) | I2C_MASTER_READ, true);
    if (len > 1) {
        i2c_master_read(cmd, buf, len - 1, I2C_MASTER_ACK);
    }
    i2c_master_read_byte(cmd, buf + len - 1, I2C_MASTER_NACK);
    i2c_master_stop(cmd);
    esp_err_t ret = i2c_master_cmd_begin(AS7265x_I2C_NUM, cmd, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(cmd);
    return ret;
}

static uint16_t read_channel(uint8_t channel_reg)
{
    uint8_t buf[2] = {0, 0};
    if (i2c_read_regs(channel_reg, buf, 2) != ESP_OK) {
        return 0;
    }
    return ((uint16_t)buf[0] << 8) | buf[1];
}

esp_err_t sensors_init(void)
{
    i2c_config_t i2c_conf = {
        .mode             = I2C_MODE_MASTER,
        .sda_io_num       = PIN_AS7265x_SDA,
        .scl_io_num       = PIN_AS7265x_SCL,
        .sda_pullup_en    = GPIO_PULLUP_ENABLE,
        .scl_pullup_en    = GPIO_PULLUP_ENABLE,
        .master.clk_speed = AS7265x_I2C_FREQ,
    };
    esp_err_t ret = i2c_param_config(AS7265x_I2C_NUM, &i2c_conf);
    if (ret != ESP_OK) return ret;

    ret = i2c_driver_install(AS7265x_I2C_NUM, I2C_MODE_MASTER, 0, 0, 0);
    if (ret != ESP_OK) return ret;

    /* Probe: read device ID. */
    uint8_t id = 0;
    if (i2c_read_regs(REG_DEVICE_ID, &id, 1) != ESP_OK) {
        ESP_LOGE(TAG, "AS7265x not found on I2C1 (GPIO13/14)");
        return ESP_FAIL;
    }
    if (id != CHIP_ID_EXPECTED) {
        ESP_LOGW(TAG, "AS7265x ID 0x%02X (expected 0x%02X)", id, CHIP_ID_EXPECTED);
    }

    /* Enable UV and IR channels. */
    i2c_write_reg(REG_ENABLE_UV, 0x01);
    i2c_write_reg(REG_ENABLE_IR, 0x01);

    g_reading.available = true;
    g_last_sensor_reading.available = true;
    ESP_LOGI(TAG, "AS7265x initialized (UV + IR) on I2C1");
    return ESP_OK;
}

esp_err_t sensors_read_uv_ir(as7265x_reading_t *out)
{
    if (!g_reading.available) {
        out->uv_raw = 0;
        out->ir_raw = 0;
        out->available = false;
        return ESP_FAIL;
    }

    out->uv_raw = read_channel(REG_CH_UV_DATA);
    out->ir_raw = read_channel(REG_CH_IR_DATA);
    out->available = true;

    g_last_sensor_reading = *out;
    return ESP_OK;
}
