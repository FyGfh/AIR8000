/**
 * @file protocol.h
 * @brief VDM MCU 通讯协议定义
 * @version 1.0
 * @date 2025.12.13
 *
 * 帧格式:
 * [SYNC1 0xAA][SYNC2 0x55][VER][TYPE][SEQ][CMD_H][CMD_L][LEN_H][LEN_L][DATA...][CRC_H][CRC_L]
 */

#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include <string.h>

// ==================== 帧格式常量 ====================
#define FRAME_SYNC1         0xAA
#define FRAME_SYNC2         0x55
#define FRAME_VERSION       0x10        // V1.0

#define FRAME_HEADER_SIZE   9           // SYNC(2) + VER(1) + TYPE(1) + SEQ(1) + CMD(2) + LEN(2)
#define FRAME_CRC_SIZE      2
#define FRAME_MIN_SIZE      11          // HEADER(9) + CRC(2)
#define FRAME_MAX_DATA_SIZE 65535

// 帧字段偏移
#define OFFSET_SYNC1    0
#define OFFSET_SYNC2    1
#define OFFSET_VER      2
#define OFFSET_TYPE     3
#define OFFSET_SEQ      4
#define OFFSET_CMD_H    5
#define OFFSET_CMD_L    6
#define OFFSET_LEN_H    7
#define OFFSET_LEN_L    8
#define OFFSET_DATA     9

// ==================== 帧类型 (TYPE) ====================
typedef enum {
    TYPE_REQUEST        = 0x00,     // 请求
    TYPE_RESPONSE       = 0x01,     // 响应 (带数据)
    TYPE_NOTIFY         = 0x02,     // 通知/推送
    TYPE_ACK            = 0x03,     // 确认
    TYPE_NACK           = 0x04,     // 否定确认/错误

    // RS485透传 (0x80-0xEF)
    TYPE_PASSTHROUGH_MIN = 0x80,
    TYPE_PASSTHROUGH_MAX = 0xEF,
} frame_type_t;

// ==================== 命令组 (CMD高字节) ====================
typedef enum {
    CMD_GROUP_SYSTEM    = 0x00,     // 系统命令
    CMD_GROUP_QUERY     = 0x01,     // 查询命令
    CMD_GROUP_MOTOR     = 0x30,     // 电机控制
    CMD_GROUP_SENSOR    = 0x40,     // 传感器
    CMD_GROUP_DEVICE    = 0x50,     // 设备控制
    CMD_GROUP_CONFIG    = 0x60,     // 配置管理
    CMD_GROUP_DEBUG     = 0xF0,     // 调试命令
} cmd_group_t;

// ==================== 系统命令 (0x00xx) ====================
typedef enum {
    CMD_SYS_PING        = 0x0001,   // 心跳
    CMD_SYS_VERSION     = 0x0002,   // 获取版本
    CMD_SYS_RESET       = 0x0003,   // 复位
    CMD_SYS_SLEEP       = 0x0004,   // 休眠
    CMD_SYS_WAKEUP      = 0x0005,   // 唤醒
    CMD_SYS_SET_RTC     = 0x0010,   // 设置RTC
    CMD_SYS_GET_RTC     = 0x0011,   // 获取RTC
    CMD_SYS_TEMP_CTRL   = 0x0020,   // 温控
} cmd_system_t;

// ==================== 查询命令 (0x01xx) ====================
typedef enum {
    CMD_QUERY_POWER     = 0x0101,   // 电源ADC
    CMD_QUERY_STATUS    = 0x0102,   // 系统状态
    CMD_QUERY_NETWORK   = 0x0103,   // 网络状态
} cmd_query_t;

// ==================== 电机命令 (0x30xx) ====================
typedef enum {
    CMD_MOTOR_ROTATE    = 0x3001,   // 旋转到角度
    CMD_MOTOR_ENABLE    = 0x3002,   // 启用
    CMD_MOTOR_DISABLE   = 0x3003,   // 禁用
    CMD_MOTOR_STOP      = 0x3004,   // 急停
    CMD_MOTOR_SET_ORIGIN= 0x3005,   // 设置原点
    CMD_MOTOR_GET_POS   = 0x3006,   // 查询位置
    CMD_MOTOR_SET_VEL   = 0x3007,   // 设置速度
    CMD_MOTOR_ROTATE_REL= 0x3008,   // 相对旋转
    CMD_MOTOR_GET_ALL   = 0x3010,   // 查询所有电机
} cmd_motor_t;

// ==================== 传感器命令 (0x40xx) ====================
typedef enum {
    CMD_SENSOR_READ_TEMP = 0x4001,  // 读取温度
    CMD_SENSOR_READ_ALL  = 0x4002,  // 读取所有
    CMD_SENSOR_CONFIG    = 0x4010,  // 配置采集
} cmd_sensor_t;

// ==================== 设备控制命令 (0x50xx) ====================
typedef enum {
    CMD_DEV_HEATER      = 0x5001,   // 加热器
    CMD_DEV_FAN         = 0x5002,   // 风扇
    CMD_DEV_LED         = 0x5003,   // LED
    CMD_DEV_LASER       = 0x5004,   // 激光
    CMD_DEV_PWM_LIGHT   = 0x5005,   // PWM补光灯
    CMD_DEV_GET_STATE   = 0x5010,   // 查询状态
} cmd_device_t;

// ==================== 电机ID ====================
typedef enum {
    MOTOR_ID_X      = 0x01,
    MOTOR_ID_Y      = 0x02,
    MOTOR_ID_Z      = 0x03,
    MOTOR_ID_ALL    = 0xFF,
} motor_id_t;

// ==================== 设备ID ====================
typedef enum {
    DEV_ID_HEATER1      = 0x01,
    DEV_ID_HEATER2      = 0x02,
    DEV_ID_FAN1         = 0x10,
    DEV_ID_LED          = 0x20,
    DEV_ID_LASER        = 0x30,
    DEV_ID_PWM_LIGHT    = 0x40,
} device_id_t;

// ==================== 设备状态 ====================
typedef enum {
    DEV_STATE_OFF   = 0x00,
    DEV_STATE_ON    = 0x01,
    DEV_STATE_BLINK = 0x02,
} device_state_t;

// ==================== 错误码 ====================
typedef enum {
    ERR_UNKNOWN_CMD     = 0x01,
    ERR_INVALID_PARAM   = 0x02,
    ERR_DEVICE_BUSY     = 0x03,
    ERR_NOT_READY       = 0x04,
    ERR_EXEC_FAILED     = 0x05,
    ERR_TIMEOUT         = 0x06,
    ERR_CRC_ERROR       = 0x07,
    ERR_VERSION_UNSUP   = 0x08,
} error_code_t;

// ==================== 数据结构 ====================

// 解析后的帧结构
typedef struct {
    uint8_t  version;
    uint8_t  type;
    uint8_t  seq;
    uint16_t cmd;
    uint16_t len;
    uint8_t *data;
    uint16_t crc;
} protocol_frame_t;

// ==================== 工具函数 ====================

// float转大端序
static inline void float_to_be(float val, uint8_t *out) {
    union { float f; uint32_t u; } conv;
    conv.f = val;
    out[0] = (conv.u >> 24) & 0xFF;
    out[1] = (conv.u >> 16) & 0xFF;
    out[2] = (conv.u >> 8) & 0xFF;
    out[3] = conv.u & 0xFF;
}

// 大端序转float
static inline float be_to_float(const uint8_t *in) {
    union { float f; uint32_t u; } conv;
    conv.u = ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16) |
             ((uint32_t)in[2] << 8) | in[3];
    return conv.f;
}

// u16转大端序
static inline void u16_to_be(uint16_t val, uint8_t *out) {
    out[0] = (val >> 8) & 0xFF;
    out[1] = val & 0xFF;
}

// 大端序转u16
static inline uint16_t be_to_u16(const uint8_t *in) {
    return ((uint16_t)in[0] << 8) | in[1];
}

// i16转大端序
static inline void i16_to_be(int16_t val, uint8_t *out) {
    out[0] = (val >> 8) & 0xFF;
    out[1] = val & 0xFF;
}

// 大端序转i16
static inline int16_t be_to_i16(const uint8_t *in) {
    return (int16_t)(((uint16_t)in[0] << 8) | in[1]);
}

// ==================== CRC-16/MODBUS ====================

static inline uint16_t crc16_modbus(const uint8_t *data, uint16_t len) {
    uint16_t crc = 0xFFFF;
    for (uint16_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (uint8_t j = 0; j < 8; j++) {
            if (crc & 0x0001)
                crc = (crc >> 1) ^ 0xA001;
            else
                crc >>= 1;
        }
    }
    return crc;
}

// ==================== 帧构造函数 ====================

// 序列号生成器
static uint8_t _seq_counter = 0;
static inline uint8_t next_seq(void) {
    return _seq_counter++;
}

/**
 * 构造帧
 * @param buf 输出缓冲区
 * @param type 帧类型
 * @param seq 序列号
 * @param cmd 命令码
 * @param data 数据
 * @param data_len 数据长度
 * @return 帧总长度
 */
static inline int build_frame(uint8_t *buf, uint8_t type, uint8_t seq,
                               uint16_t cmd, const uint8_t *data, uint16_t data_len) {
    // 帧头
    buf[OFFSET_SYNC1] = FRAME_SYNC1;
    buf[OFFSET_SYNC2] = FRAME_SYNC2;
    buf[OFFSET_VER] = FRAME_VERSION;
    buf[OFFSET_TYPE] = type;
    buf[OFFSET_SEQ] = seq;
    buf[OFFSET_CMD_H] = (cmd >> 8) & 0xFF;
    buf[OFFSET_CMD_L] = cmd & 0xFF;
    buf[OFFSET_LEN_H] = (data_len >> 8) & 0xFF;
    buf[OFFSET_LEN_L] = data_len & 0xFF;

    // 数据
    if (data && data_len > 0) {
        memcpy(&buf[OFFSET_DATA], data, data_len);
    }

    // CRC (从VER开始计算)
    uint16_t crc_len = 7 + data_len;  // VER到DATA
    uint16_t crc = crc16_modbus(&buf[OFFSET_VER], crc_len);
    buf[OFFSET_DATA + data_len] = (crc >> 8) & 0xFF;
    buf[OFFSET_DATA + data_len + 1] = crc & 0xFF;

    return FRAME_HEADER_SIZE + data_len + FRAME_CRC_SIZE;
}

// 构造请求帧
static inline int build_request(uint8_t *buf, uint16_t cmd,
                                 const uint8_t *data, uint16_t data_len) {
    return build_frame(buf, TYPE_REQUEST, next_seq(), cmd, data, data_len);
}

// 构造ACK帧
static inline int build_ack(uint8_t *buf, uint8_t seq, uint16_t cmd) {
    return build_frame(buf, TYPE_ACK, seq, cmd, NULL, 0);
}

// 构造响应帧
static inline int build_response(uint8_t *buf, uint8_t seq, uint16_t cmd,
                                  const uint8_t *data, uint16_t data_len) {
    return build_frame(buf, TYPE_RESPONSE, seq, cmd, data, data_len);
}

// 构造NACK帧
static inline int build_nack(uint8_t *buf, uint8_t seq, uint16_t cmd, uint8_t error_code) {
    return build_frame(buf, TYPE_NACK, seq, cmd, &error_code, 1);
}

// ==================== 特定命令构造 ====================

// 电机旋转命令
static inline int build_motor_rotate(uint8_t *buf, uint8_t motor_id,
                                      float angle, float velocity) {
    uint8_t data[9];
    data[0] = motor_id;
    float_to_be(angle, &data[1]);
    float_to_be(velocity, &data[5]);
    return build_request(buf, CMD_MOTOR_ROTATE, data, 9);
}

// 电机使能命令
static inline int build_motor_enable(uint8_t *buf, uint8_t motor_id) {
    return build_request(buf, CMD_MOTOR_ENABLE, &motor_id, 1);
}

// 电机禁用命令
static inline int build_motor_disable(uint8_t *buf, uint8_t motor_id) {
    return build_request(buf, CMD_MOTOR_DISABLE, &motor_id, 1);
}

// 电机查询位置
static inline int build_motor_get_pos(uint8_t *buf, uint8_t motor_id) {
    return build_request(buf, CMD_MOTOR_GET_POS, &motor_id, 1);
}

// 设备控制命令
static inline int build_device_ctrl(uint8_t *buf, uint16_t cmd,
                                     uint8_t device_id, uint8_t state) {
    uint8_t data[2] = {device_id, state};
    return build_request(buf, cmd, data, 2);
}

// 传感器读取
static inline int build_sensor_read(uint8_t *buf, uint8_t sensor_id) {
    return build_request(buf, CMD_SENSOR_READ_TEMP, &sensor_id, 1);
}

// ==================== 帧解析 ====================

// 检查帧头同步
static inline int check_sync(const uint8_t *buf) {
    return buf[0] == FRAME_SYNC1 && buf[1] == FRAME_SYNC2;
}

// 判断是否为透传帧
static inline int is_passthrough(uint8_t type) {
    return type >= TYPE_PASSTHROUGH_MIN && type <= TYPE_PASSTHROUGH_MAX;
}

// 解析帧 (不验证CRC)
static inline int parse_frame(const uint8_t *buf, uint16_t buf_len,
                               protocol_frame_t *frame) {
    if (buf_len < FRAME_MIN_SIZE) return -1;
    if (!check_sync(buf)) return -2;

    frame->version = buf[OFFSET_VER];
    frame->type = buf[OFFSET_TYPE];
    frame->seq = buf[OFFSET_SEQ];
    frame->cmd = be_to_u16(&buf[OFFSET_CMD_H]);
    frame->len = be_to_u16(&buf[OFFSET_LEN_H]);

    if (buf_len < FRAME_HEADER_SIZE + frame->len + FRAME_CRC_SIZE) {
        return -3;  // 数据不完整
    }

    frame->data = (uint8_t *)&buf[OFFSET_DATA];
    frame->crc = be_to_u16(&buf[OFFSET_DATA + frame->len]);

    return FRAME_HEADER_SIZE + frame->len + FRAME_CRC_SIZE;
}

// 获取命令组
static inline uint8_t get_cmd_group(uint16_t cmd) {
    return (cmd >> 8) & 0xFF;
}

// 获取命令ID
static inline uint8_t get_cmd_id(uint16_t cmd) {
    return cmd & 0xFF;
}

#endif // PROTOCOL_H
