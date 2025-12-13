# VDM MCU 通讯协议

## 概述

本协议用于 Hi3516cv610 与 Air8000 之间的通信，支持 RS485 透传。

### 设计特点

- **帧头同步**: 0xAA 0x55 帧头，解决粘包/断包
- **协议版本**: 支持后续升级
- **序列号**: 请求/响应匹配，支持异步和重传
- **帧类型**: 区分请求/响应/通知/确认
- **16位命令码**: 支持 256组 × 256命令

---

## 帧格式

```
┌────────┬────────┬─────┬───────┬───────┬─────────┬─────────┬──────────┬─────────┐
│ SYNC1  │ SYNC2  │ VER │ TYPE  │  SEQ  │  CMD    │   LEN   │   DATA   │  CRC16  │
│ 0xAA   │ 0x55   │ 1B  │  1B   │  1B   │   2B    │   2B    │   NB     │   2B    │
└────────┴────────┴─────┴───────┴───────┴─────────┴─────────┴──────────┴─────────┘
│←────── 固定头部 9字节 ───────→│←─ 可变 ─→│←─ 2B ─→│
```

### 字段说明

| 字段 | 偏移 | 长度 | 说明 |
|------|------|------|------|
| SYNC1 | 0 | 1 | 同步字节1: 0xAA |
| SYNC2 | 1 | 1 | 同步字节2: 0x55 |
| VER | 2 | 1 | 协议版本: 0x10 (V1.0) |
| TYPE | 3 | 1 | 帧类型 |
| SEQ | 4 | 1 | 序列号 (0-255循环) |
| CMD | 5-6 | 2 | 命令码 (大端序) |
| LEN | 7-8 | 2 | DATA长度 (大端序) |
| DATA | 9+ | N | 数据负载 |
| CRC16 | 末2B | 2 | CRC校验 (大端序) |

### 帧长度

- **最小帧**: 11 字节 (无DATA)
- **最大帧**: 9 + 65535 + 2 = 65546 字节

---

## 帧类型 (TYPE)

| 值 | 名称 | 说明 | 方向 |
|----|------|------|------|
| 0x00 | REQUEST | 请求命令 | Hi3516 → Air8000 |
| 0x01 | RESPONSE | 响应 (带数据) | Air8000 → Hi3516 |
| 0x02 | NOTIFY | 通知/推送 | 双向 |
| 0x03 | ACK | 简单确认 | Air8000 → Hi3516 |
| 0x04 | NACK | 否定确认/错误 | Air8000 → Hi3516 |
| 0x80-0xEF | PASSTHROUGH | RS485透传 | 双向 |

### 请求-响应匹配

```
Hi3516cv610                          Air8000
    │                                   │
    │ REQUEST (SEQ=0x01, CMD=0x3001)    │
    │ ────────────────────────────────→ │
    │                                   │ 执行命令
    │ RESPONSE (SEQ=0x01, CMD=0x3001)   │
    │ ←──────────────────────────────── │
    │                                   │
    │ REQUEST (SEQ=0x02, CMD=0x4001)    │
    │ ────────────────────────────────→ │
    │                                   │
    │ ACK (SEQ=0x02, CMD=0x4001)        │
    │ ←──────────────────────────────── │
```

**SEQ规则**:
- 请求方维护SEQ递增 (0-255循环)
- 响应方回复相同SEQ
- 用于异步请求匹配和超时重传

---

## 命令码 (CMD)

16位命令码，大端序:

```
CMD = [GROUP (8bit)] [ID (8bit)]

示例:
0x3001 = GROUP=0x30(电机) + ID=0x01(旋转)
0x4002 = GROUP=0x40(传感器) + ID=0x02(读取全部)
```

### 命令组分配

| GROUP | 范围 | 名称 | 说明 |
|-------|------|------|------|
| 0x00 | 0x0000-0x00FF | SYSTEM | 系统命令 |
| 0x01 | 0x0100-0x01FF | QUERY | 查询命令 |
| 0x30 | 0x3000-0x30FF | MOTOR | 电机控制 |
| 0x40 | 0x4000-0x40FF | SENSOR | 传感器 |
| 0x50 | 0x5000-0x50FF | DEVICE | 设备控制 |
| 0x60 | 0x6000-0x60FF | CONFIG | 配置管理 |
| 0x80-0xEF | - | PASSTHROUGH | RS485透传 |
| 0xF0 | 0xF000-0xF0FF | DEBUG | 调试命令 |

---

## 0x30 电机命令组

### 命令列表

| CMD | 名称 | DATA格式 | 说明 |
|-----|------|----------|------|
| 0x3001 | MOTOR_ROTATE | [motor_id u8][angle f32][velocity f32] | 旋转到角度 |
| 0x3002 | MOTOR_ENABLE | [motor_id u8] | 启用电机 |
| 0x3003 | MOTOR_DISABLE | [motor_id u8] | 禁用电机 |
| 0x3004 | MOTOR_STOP | [motor_id u8] | 急停 |
| 0x3005 | MOTOR_SET_ORIGIN | [motor_id u8] | 设置原点 |
| 0x3006 | MOTOR_GET_POS | [motor_id u8] | 查询位置 |
| 0x3007 | MOTOR_SET_VEL | [motor_id u8][velocity f32] | 设置速度 |
| 0x3008 | MOTOR_ROTATE_REL | [motor_id u8][angle f32][velocity f32] | 相对旋转 |
| 0x3010 | MOTOR_GET_ALL | - | 查询所有电机状态 |

### 电机ID

| ID | 名称 | 说明 |
|----|------|------|
| 0x01 | MOTOR_X | X轴/水平旋转 |
| 0x02 | MOTOR_Y | Y轴/俯仰 |
| 0x03 | MOTOR_Z | Z轴/变焦 |
| 0xFF | MOTOR_ALL | 所有电机 |

### 示例：旋转电机1到90度，速度10.0

```
请求帧:
  SYNC   = AA 55
  VER    = 30
  TYPE   = 00 (REQUEST)
  SEQ    = 01
  CMD    = 30 01 (MOTOR_ROTATE)
  LEN    = 00 09 (9字节)
  DATA   = 01 42B40000 41200000
           │  │        └─ velocity=10.0 (f32)
           │  └────────── angle=90.0 (f32)
           └───────────── motor_id=1
  CRC    = XX XX

完整帧 (20字节):
AA 55 30 00 01 30 01 00 09 01 42 B4 00 00 41 20 00 00 [CRC_H] [CRC_L]
```

### 响应：电机位置查询

```
请求:
AA 55 30 00 02 30 06 00 01 01 [CRC]
                          └─ motor_id=1

响应:
AA 55 30 01 02 30 06 00 05 01 42B40000 [CRC]
         │  │              │  └─ position=90.0
         │  │              └───── motor_id=1
         │  └──────────────────── SEQ=02 (匹配请求)
         └─────────────────────── TYPE=RESPONSE
```

---

## 0x40 传感器命令组

| CMD | 名称 | DATA格式 | 说明 |
|-----|------|----------|------|
| 0x4001 | SENSOR_READ_TEMP | [sensor_id u8] | 读取温度 |
| 0x4002 | SENSOR_READ_ALL | - | 读取所有传感器 |
| 0x4010 | SENSOR_CONFIG | [sensor_id u8][interval_ms u16] | 配置采集间隔 |

### 响应格式

```
温度响应 DATA: [sensor_id u8][temperature f32]
全部响应 DATA: [count u8][sensor1_id u8][temp1 f32][sensor2_id u8][temp2 f32]...
```

---

## 0x50 设备控制命令组

| CMD | 名称 | DATA格式 | 说明 |
|-----|------|----------|------|
| 0x5001 | DEV_HEATER | [device_id u8][state u8] | 加热器控制 |
| 0x5002 | DEV_FAN | [device_id u8][state u8] | 风扇控制 |
| 0x5003 | DEV_LED | [device_id u8][state u8] | LED控制 |
| 0x5004 | DEV_LASER | [device_id u8][state u8] | 激光控制 |
| 0x5005 | DEV_PWM_LIGHT | [device_id u8][brightness u8] | PWM补光灯 |
| 0x5010 | DEV_GET_STATE | [device_id u8] | 查询设备状态 |

### 设备ID

| ID | 设备 |
|----|------|
| 0x01 | 加热器1 |
| 0x02 | 加热器2 |
| 0x10 | 风扇1 |
| 0x20 | LED指示灯 |
| 0x30 | 激光器 |
| 0x40 | PWM补光灯 |

### 状态值

| 值 | 状态 |
|----|------|
| 0x00 | OFF |
| 0x01 | ON |
| 0x02 | BLINK (仅LED) |
| 0x00-0x64 | 亮度0-100% (PWM) |

---

## 0x00 系统命令组

| CMD | 名称 | DATA格式 | 说明 |
|-----|------|----------|------|
| 0x0001 | SYS_PING | - | 心跳/连通测试 |
| 0x0002 | SYS_VERSION | - | 获取版本信息 |
| 0x0003 | SYS_RESET | [reset_type u8] | 系统复位 |
| 0x0004 | SYS_SLEEP | [duration_sec u16] | 休眠 |
| 0x0005 | SYS_WAKEUP | - | 唤醒 |
| 0x0010 | SYS_SET_RTC | [year u16][mon u8][day u8][hour u8][min u8][sec u8] | 设置RTC |
| 0x0011 | SYS_GET_RTC | - | 获取RTC |
| 0x0020 | SYS_TEMP_CTRL | [enable u8][target_temp i16] | 温控设置 |

---

## 0x01 查询命令组

| CMD | 名称 | 说明 |
|-----|------|------|
| 0x0101 | QUERY_POWER | 查询电源ADC |
| 0x0102 | QUERY_STATUS | 查询系统状态 |
| 0x0103 | QUERY_NETWORK | 查询网络状态 |

---

## 0x80-0xEF RS485透传

透传帧使用 TYPE=0x80-0xEF，Air8000 不解析 DATA，直接转发到 RS485。

```
Hi3516cv610                 Air8000                   RS485设备
    │                          │                          │
    │ TYPE=0x80, DATA=[...]    │  原样转发                 │
    │ ───────────────────────→ │ ───────────────────────→ │
    │                          │                          │
    │ TYPE=0x80, DATA=[...]    │  原样转发                 │
    │ ←─────────────────────── │ ←─────────────────────── │
```

**透传时CMD字段可用于区分RS485设备地址或子协议**

---

## 错误响应

### NACK帧 (TYPE=0x04)

```
DATA格式: [error_code u8][error_msg string (可选)]
```

| error_code | 说明 |
|------------|------|
| 0x01 | 未知命令 |
| 0x02 | 参数错误 |
| 0x03 | 设备忙 |
| 0x04 | 设备未就绪 |
| 0x05 | 执行失败 |
| 0x06 | 超时 |
| 0x07 | CRC错误 |
| 0x08 | 版本不支持 |

---

## CRC校验

- **算法**: CRC-16/MODBUS
- **计算范围**: VER + TYPE + SEQ + CMD + LEN + DATA (不含SYNC)
- **字节序**: 大端序

```c
// CRC计算范围: 从VER开始到DATA结束
uint16_t crc = crc16_modbus(&frame[2], 7 + data_len);
```

---

## 通知帧 (NOTIFY)

Air8000 可主动推送状态变化：

```
示例: 温度超限告警
AA 55 30 02 00 40 01 00 05 01 42C80000 [CRC]
         │  │                 │  └─ temp=100.0 (超限!)
         │  │                 └───── sensor_id=1
         │  └─────────────────────── SEQ=00 (通知不需要响应)
         └────────────────────────── TYPE=NOTIFY
```

---

## 数据类型

| 类型 | 长度 | 字节序 | 说明 |
|------|------|--------|------|
| u8 | 1 | - | 无符号8位 |
| u16 | 2 | 大端 | 无符号16位 |
| u32 | 4 | 大端 | 无符号32位 |
| i16 | 2 | 大端 | 有符号16位 |
| i32 | 4 | 大端 | 有符号32位 |
| f32 | 4 | 大端 | IEEE754单精度浮点 |
| string | N | - | UTF-8字符串 (可选null结尾) |

### f32 常用值

| 数值 | 十六进制 |
|------|----------|
| 0.0 | 00 00 00 00 |
| 1.0 | 3F 80 00 00 |
| 10.0 | 41 20 00 00 |
| 90.0 | 42 B4 00 00 |
| 180.0 | 43 34 00 00 |
| -1.0 | BF 80 00 00 |

---

## 完整交互示例

### 场景1：电机控制

```
# 1. 启用电机1
Hi3516 → Air8000:
AA 55 30 00 01 30 02 00 01 01 [CRC]
         │  │  │     │     └─ motor_id=1
         │  │  │     └─────── LEN=1
         │  │  └───────────── CMD=MOTOR_ENABLE
         │  └──────────────── SEQ=01
         └─────────────────── TYPE=REQUEST

Air8000 → Hi3516:
AA 55 30 03 01 30 02 00 00 [CRC]
         │  │              └─ LEN=0 (ACK无数据)
         │  └───────────────── SEQ=01 (匹配)
         └──────────────────── TYPE=ACK

# 2. 旋转到90度
Hi3516 → Air8000:
AA 55 30 00 02 30 01 00 09 01 42B40000 41200000 [CRC]

Air8000 → Hi3516:
AA 55 30 03 02 30 01 00 00 [CRC]

# 3. 查询位置
Hi3516 → Air8000:
AA 55 30 00 03 30 06 00 01 01 [CRC]

Air8000 → Hi3516:
AA 55 30 01 03 30 06 00 05 01 42B40000 [CRC]
                              │  └─ pos=90.0
                              └───── motor_id=1
```

### 场景2：异常处理

```
# 发送无效命令
Hi3516 → Air8000:
AA 55 30 00 05 FF FF 00 00 [CRC]

# 返回NACK
Air8000 → Hi3516:
AA 55 30 04 05 FF FF 00 01 01 [CRC]
         │  │              └─ error_code=0x01 (未知命令)
         │  └───────────────── SEQ=05 (匹配)
         └──────────────────── TYPE=NACK
```

---

## Air8000 处理逻辑

```lua
function handle_frame(frame)
    -- 1. 验证帧头
    if frame[1] ~= 0xAA or frame[2] ~= 0x55 then
        return  -- 丢弃
    end

    -- 2. 检查版本
    local ver = frame[3]
    if ver ~= 0x10 then
        return send_nack(seq, cmd, ERROR_VERSION)
    end

    local frame_type = frame[4]
    local seq = frame[5]
    local cmd = (frame[6] << 8) | frame[7]

    -- 3. RS485透传
    if frame_type >= 0x80 and frame_type <= 0xEF then
        rs485_write(frame)  -- 原样转发
        return
    end

    -- 4. 本地命令 (不验证CRC)
    local data = extract_data(frame)
    local result = execute_command(cmd, data)

    -- 5. 发送响应
    if result.has_data then
        send_response(seq, cmd, result.data)
    else
        send_ack(seq, cmd)
    end
end
```

---

## 快速参考

### 帧结构

```
AA 55 [VER] [TYPE] [SEQ] [CMD_H CMD_L] [LEN_H LEN_L] [DATA...] [CRC_H CRC_L]
```

### TYPE速查

| TYPE | 名称 |
|------|------|
| 0x00 | REQUEST |
| 0x01 | RESPONSE |
| 0x02 | NOTIFY |
| 0x03 | ACK |
| 0x04 | NACK |
| 0x80+ | PASSTHROUGH |

### CMD速查

| CMD | 名称 |
|------|------|
| 0x0001 | SYS_PING |
| 0x3001 | MOTOR_ROTATE |
| 0x3002 | MOTOR_ENABLE |
| 0x3006 | MOTOR_GET_POS |
| 0x4001 | SENSOR_READ_TEMP |
| 0x5001 | DEV_HEATER |

---
