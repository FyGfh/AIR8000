# VDM Air8000 命令开发指南

本文档介绍如何在 Air8000 MCU 端开发新的命令处理器，以及如何在 Hi3516CV610 主控端对接。

## 目录

- [架构概述](#架构概述)
- [协议格式](#协议格式)
- [MCU 端开发 (Luna/Lua)](#mcu-端开发-lunalua)
- [主控端开发 (Rust)](#主控端开发-rust)
- [完整示例](#完整示例)
- [调试技巧](#调试技巧)

---

## 架构概述

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Hi3516CV610 主控                              │
│  ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐ │
│  │   RPC 服务层    │───▶│  mcu-air-8000    │───▶│  /dev/ttyACM2      │ │
│  │ (get_adc_voltage)│    │  (Rust 协议库)   │    │  (USB 虚拟串口)     │ │
│  └─────────────────┘    └──────────────────┘    └──────────┬──────────┘ │
└────────────────────────────────────────────────────────────┼────────────┘
                                                              │ USB CDC ACM
┌─────────────────────────────────────────────────────────────┼────────────┐
│                           Air8000 MCU                       │            │
│  ┌─────────────────┐    ┌──────────────────┐    ┌──────────▼──────────┐ │
│  │   业务处理      │◀───│  usb_vuart_comm  │◀───│     VUART_0        │ │
│  │ (main.lua)      │    │  (协议解析)       │    │  (USB 虚拟串口)     │ │
│  └─────────────────┘    └──────────────────┘    └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 通信流程

```
1. 主控发送请求帧 ──────▶ Air8000 接收并解析
2. Air8000 执行命令 ────▶ 调用注册的处理器
3. Air8000 构造响应 ────▶ 发送 ACK/NACK/RESPONSE
4. 主控接收响应 ────────▶ 解析并返回结果
```

---

## 协议格式

### 帧结构

```
[0xAA][0x55][VER][TYPE][SEQ][CMD_H][CMD_L][LEN_H][LEN_L][DATA...][CRC_H][CRC_L]
  帧头      版本  类型  序列号   命令码(16位)    数据长度      数据      CRC校验
```

| 字段 | 大小 | 说明 |
|------|------|------|
| SYNC | 2B | 帧头同步字 `0xAA 0x55` |
| VER | 1B | 协议版本 `0x10` (V1.0) |
| TYPE | 1B | 帧类型 (见下表) |
| SEQ | 1B | 序列号 (请求/响应匹配) |
| CMD | 2B | 命令码 (大端序) |
| LEN | 2B | 数据长度 (大端序) |
| DATA | NB | 负载数据 |
| CRC | 2B | CRC-16/MODBUS 校验 |

### 帧类型

| 类型 | 值 | 说明 |
|------|------|------|
| REQUEST | 0x00 | 请求帧 (主控 → MCU) |
| RESPONSE | 0x01 | 响应帧 (带数据) |
| NOTIFY | 0x02 | 通知帧 (MCU 主动上报) |
| ACK | 0x03 | 确认帧 (无数据) |
| NACK | 0x04 | 拒绝帧 (带错误码) |

### 命令码分组

| 分组 | 范围 | 说明 |
|------|------|------|
| 系统命令 | 0x00xx | PING、版本、复位等 |
| 查询命令 | 0x01xx | 电源、状态、网络查询 |
| 电机控制 | 0x30xx | 旋转、使能、停止等 |
| 传感器 | 0x40xx | 温度、湿度读取 |
| 设备控制 | 0x50xx | 加热器、风扇、LED 等 |
| 配置管理 | 0x60xx | 参数读写 |
| 调试命令 | 0xF0xx | 调试专用 |

---

## MCU 端开发 (Luna/Lua)

### 文件结构

```
vdm-mcu-air8000/
├── src/
│   ├── main.lua              # 主程序，注册命令处理器
│   ├── usb_vuart_comm.lua    # 通信协议模块
│   ├── ds18b20_sensor.lua    # DS18B20 温度传感器
│   └── dm_can_motor.lua      # 达妙电机控制
├── protocol.h                # 协议定义 (C 头文件，供参考)
└── docs/
    └── protocol/PROTOCOL.md  # 协议文档
```

### 注册命令处理器

在 `main.lua` 中使用 `usb_vuart.on_cmd()` 注册命令：

```lua
local usb_vuart = require "usb_vuart_comm"
local CMD = usb_vuart.CMD
local RESULT = usb_vuart.CMD_RESULT
local ERROR = usb_vuart.ERROR

-- 注册命令处理器
-- 函数签名: function(seq, data) -> result, resp_data, error_code
usb_vuart.on_cmd(CMD.YOUR_COMMAND, function(seq, data)
    -- seq: 请求序列号 (用于日志)
    -- data: 请求数据 (字符串，可能为空)

    -- 处理逻辑...

    -- 返回结果
    return RESULT.ACK  -- 或 RESULT.RESPONSE, RESULT.NACK
end)
```

### 返回值类型

| 返回值 | 说明 | 示例 |
|--------|------|------|
| `RESULT.ACK` | 发送确认帧 (无数据) | `return RESULT.ACK` |
| `RESULT.NACK` | 发送拒绝帧 | `return RESULT.NACK, nil, ERROR.INVALID_PARAM` |
| `RESULT.RESPONSE` | 发送响应数据帧 | `return RESULT.RESPONSE, resp_data` |
| `RESULT.NONE` | 不发送响应 (异步处理) | `return RESULT.NONE` |

### 错误码

```lua
usb_vuart.ERROR = {
    UNKNOWN_CMD = 0x01,       -- 未知命令
    INVALID_PARAM = 0x02,     -- 无效参数
    DEVICE_BUSY = 0x03,       -- 设备忙
    NOT_READY = 0x04,         -- 未就绪
    EXEC_FAILED = 0x05,       -- 执行失败
    TIMEOUT = 0x06,           -- 超时
    CRC_ERROR = 0x07,         -- CRC 校验错误
    VERSION_UNSUPPORTED = 0x08, -- 版本不支持
}
```

### 数据编码

**大端序 (Big-Endian)** 用于多字节数据：

```lua
-- u16 编码
local function encode_u16(value)
    return string.char(
        bit.rshift(value, 8),    -- 高字节
        bit.band(value, 0xFF)    -- 低字节
    )
end

-- u16 解码
local function decode_u16(data, offset)
    offset = offset or 1
    return data:byte(offset) * 256 + data:byte(offset + 1)
end

-- float 编码 (IEEE 754 大端序)
local function encode_float(value)
    return string.pack(">f", value)
end

-- float 解码
local function decode_float(data, offset)
    offset = offset or 1
    return string.unpack(">f", data, offset)
end
```

### 示例：自定义命令

```lua
-- 定义命令码 (在 usb_vuart_comm.lua 的 CMD 表中添加)
-- MY_CUSTOM_CMD = 0x6001

-- 注册处理器
usb_vuart.on_cmd(0x6001, function(seq, data)
    -- 1. 参数验证
    if #data < 2 then
        log.warn("cmd", "参数不足")
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end

    -- 2. 解析参数
    local param1 = data:byte(1)
    local param2 = data:byte(2)

    -- 3. 执行业务逻辑
    local result = do_something(param1, param2)

    -- 4. 构造响应
    if result then
        local resp_data = string.char(0x00, result)  -- 状态码 + 结果
        return RESULT.RESPONSE, resp_data
    else
        return RESULT.NACK, nil, ERROR.EXEC_FAILED
    end
end)
```

---

## 主控端开发 (Rust)

### 项目结构

```
mcu-air-8000/                    # Rust 通信库
├── src/
│   ├── lib.rs                  # 库入口
│   ├── protocol.rs             # 协议定义和帧编解码
│   ├── serial_comm.rs          # 串口通信 API
│   └── error.rs                # 错误类型
└── Cargo.toml

inteagle_vdm/src/rpc_services/  # RPC 服务层
├── mod.rs                      # 模块注册
├── get_adc_voltage.rs          # ADC 电压查询服务
└── your_new_service.rs         # 你的新服务
```

### Step 1: 添加命令码 (protocol.rs)

```rust
// mcu-air-8000/src/protocol.rs

/// 命令码
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum Command {
    // ... 现有命令 ...

    // 你的新命令
    MyCustomCmd = 0x6001,
}
```

### Step 2: 添加响应结构 (protocol.rs)

```rust
/// 自定义命令响应
#[derive(Debug, Clone)]
pub struct MyCustomResponse {
    pub status: u8,
    pub value: u16,
}

impl MyCustomResponse {
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < 3 {
            return None;
        }
        let status = data[0];
        let value = ((data[1] as u16) << 8) | (data[2] as u16);
        Some(Self { status, value })
    }
}
```

### Step 3: 添加构造函数 (protocol.rs)

```rust
/// 构造自定义命令请求帧
pub fn build_my_custom_cmd(param1: u8, param2: u8) -> Frame {
    build_request(Command::MyCustomCmd, &[param1, param2])
}
```

### Step 4: 添加 API 方法 (serial_comm.rs)

```rust
impl SerialComm {
    /// 执行自定义命令
    pub fn my_custom_cmd(
        &mut self,
        param1: u8,
        param2: u8,
        timeout_ms: u64,
    ) -> Result<Option<MyCustomResponse>> {
        let frame = build_my_custom_cmd(param1, param2);
        match self.send_and_wait(&frame, timeout_ms)? {
            Some(f) if f.frame_type == FrameType::Response => {
                Ok(MyCustomResponse::from_bytes(&f.data))
            }
            Some(f) if f.frame_type == FrameType::Ack => {
                Ok(Some(MyCustomResponse { status: 0, value: 0 }))
            }
            _ => Ok(None),
        }
    }
}
```

### Step 5: 创建 RPC 服务

```rust
// inteagle_vdm/src/rpc_services/my_custom_service.rs

use serde::{Deserialize, Serialize};
use serde_json::Value;
use wy_backend_service::{
    application::command::{ctx::Context, CommandHandler},
    command,
};

/// 响应结构
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MyCustomResponse {
    pub status: u8,
    pub value: u16,
}

/// 命令处理器
#[command(
    command_type = "wyMyCustomCommand",
    description = "我的自定义命令",
    version = "1.0",
    timeout = 5
)]
pub struct MyCustomHandler;

#[async_trait::async_trait]
impl CommandHandler for MyCustomHandler {
    type Response = MyCustomResponse;

    async fn handle(&self, params: &Value, _ctx: &Context) -> eyre::Result<Self::Response> {
        // 解析参数
        let param1 = params
            .get("param1")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u8;
        let param2 = params
            .get("param2")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u8;

        // 打开串口
        let mut comm = mcu_air_8000::SerialComm::open("/dev/ttyACM2")
            .map_err(|e| eyre::eyre!("串口打开失败: {:?}", e))?;

        // 执行命令
        let result = comm
            .my_custom_cmd(param1, param2, 1000)
            .map_err(|e| eyre::eyre!("命令执行失败: {:?}", e))?
            .ok_or_else(|| eyre::eyre!("命令超时"))?;

        Ok(MyCustomResponse {
            status: result.status,
            value: result.value,
        })
    }
}
```

### Step 6: 注册模块

```rust
// inteagle_vdm/src/rpc_services/mod.rs

#[cfg(any(feature = "hardware-camera-hi3516cv610-imx415",
          feature = "hardware-camera-hi3516cv610-gc4653"))]
mod my_custom_service;
```

---

## 完整示例

### 示例：读取 ADC 电压

#### MCU 端 (main.lua)

```lua
-- ADC 配置
local ADC_CHANNEL_VBATT = 0
local ADC_CHANNEL_V12 = 1

-- 注册 QUERY_POWER (0x0101) 命令
usb_vuart.on_cmd(CMD.QUERY_POWER, function(seq, data)
    -- 读取 ADC
    local vbatt_mv = 0
    local v12_mv = 0

    if adc then
        adc.open(ADC_CHANNEL_VBATT)
        adc.open(ADC_CHANNEL_V12)

        local vbatt_raw = adc.read(ADC_CHANNEL_VBATT) or 0
        local v12_raw = adc.read(ADC_CHANNEL_V12) or 0

        adc.close(ADC_CHANNEL_VBATT)
        adc.close(ADC_CHANNEL_V12)

        -- 转换为毫伏 (根据实际分压电路调整)
        vbatt_mv = math.floor(vbatt_raw * 1024 * 11 / 4096)
        v12_mv = math.floor(v12_raw * 1024 * 11 / 4096)
    end

    -- 响应格式: [vbatt_mv u16][v12_mv u16] (大端序)
    local resp = string.char(
        bit.rshift(vbatt_mv, 8), bit.band(vbatt_mv, 0xFF),
        bit.rshift(v12_mv, 8), bit.band(v12_mv, 0xFF)
    )

    log.info("adc", string.format("电池: %dmV, 12V: %dmV", vbatt_mv, v12_mv))
    return RESULT.RESPONSE, resp
end)
```

#### 主控端 (Rust)

```rust
// 调用 API
let mut comm = SerialComm::open("/dev/ttyACM2")?;
if let Some(power) = comm.query_power(1000)? {
    println!("电池电压: {}mV", power.voltage_mv);
    println!("12V 电压: {}mV", power.current_ma);
}
```

---

## 调试技巧

### 1. 日志查看

**MCU 端**:
```lua
log.info("tag", "消息", 变量)
log.warn("tag", "警告消息")
log.error("tag", "错误消息")
```

通过 LuaTools 或串口查看日志。

**主控端**:
```rust
log::info!("消息: {:?}", variable);
log::debug!("调试信息");
```

### 2. 帧抓包

使用 `xxd` 或 `hexdump` 查看原始数据：

```bash
# 监听串口数据
cat /dev/ttyACM2 | xxd
```

### 3. 测试工具

使用 `mcu-air-8000` 库的测试示例：

```bash
cd mcu-air-8000
cargo run --example air8000_comm_test
```

### 4. 常见问题

| 问题 | 可能原因 | 解决方法 |
|------|----------|----------|
| 无响应 | 串口未打开 | 检查设备路径 `/dev/ttyACM2` |
| CRC 错误 | 数据损坏 | 检查 USB 连接 |
| NACK 响应 | 参数错误或命令不支持 | 检查参数和命令码 |
| 超时 | MCU 未处理 | 检查命令是否已注册 |

### 5. 协议验证

```lua
-- MCU 端打印接收到的帧
log.info("vuart", string.format(
    "收到请求 CMD=0x%04X SEQ=%d LEN=%d DATA=%s",
    cmd, seq, #data, data:toHex()
))
```

```rust
// 主控端打印发送的帧
let encoded = frame.encode();
log::debug!("发送帧: {:02X?}", encoded);
```

---

## 命令码快速参考

| 命令 | 码值 | 请求数据 | 响应数据 |
|------|------|----------|----------|
| SYS_PING | 0x0001 | 无 | ACK |
| SYS_VERSION | 0x0002 | 无 | [major][minor][patch][build_str] |
| QUERY_POWER | 0x0101 | 无 | [voltage_mv u16][current_ma u16] |
| QUERY_NETWORK | 0x0103 | 无 | [csq][rssi][rsrp][status][ip...] |
| MOTOR_ENABLE | 0x3002 | [motor_id] | ACK |
| MOTOR_DISABLE | 0x3003 | [motor_id] | ACK |
| MOTOR_ROTATE | 0x3001 | [motor_id][angle f32][vel f32] | ACK |
| MOTOR_GET_POS | 0x3006 | [motor_id] | [motor_id][pos f32] |
| SENSOR_READ_TEMP | 0x4001 | [sensor_id] | [sensor_id][temp f32] |
| DEV_HEATER | 0x5001 | [device_id][state] | ACK |
| DEV_FAN | 0x5002 | [device_id][state] | ACK |
| DEV_LED | 0x5003 | [device_id][state] | ACK |

---

## 参考文档

- [协议详细定义](../protocol/PROTOCOL.md)
- [达妙电机协议](../protocol/DM_MOTOR_PROTOCOL.md)
- [USB 虚拟串口说明](./README_VUART_CLIENT.md)
