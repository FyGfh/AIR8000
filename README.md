# VDM Air8000 双通道通信系统

## 项目简介

实现 **Air8000** 与 **Hi3516cv610** 的双通道USB通信系统：

1. **USB RNDIS** - 4G网络透传（Hi3516cv610通过Air8000上网）
2. **USB 虚拟串口** - 命令控制与状态查询

## 项目结构

```
vdm-mcu-air8000/
├── src/                           # Air8000源代码目录（烧录到设备）
│   ├── main.lua                   # 主程序，初始化系统并处理业务逻辑
│   ├── usb_vuart_comm.lua         # USB虚拟串口通信模块
│   ├── open_ecm.lua               # USB RNDIS网络透传配置
│   ├── dm_can_motor.lua           # DM CAN电机多电机控制驱动（v2.0重构版）
│   ├── dm_motor_bridge.lua        # DM电机USB串口桥接模块
│   └── ds18b20_sensor.lua         # DS18B20温度传感器驱动（可选）
├── docs/                          # 文档目录
│   ├── protocol/                  # 协议文档
│   │   ├── PROTOCOL.md            # 通信协议详细文档
│   │   └── DM_MOTOR_PROTOCOL.md   # DM电机控制协议（支持多电机v2.0）
│   ├── guides/                    # 使用指南
│   │   └── README_VUART_CLIENT.md # 客户端使用说明
│   └── hardware/                  # 硬件文档
│       └── 8000管脚映射表.xlsx
├── examples/                      # 示例代码
│   └── hi3516cv610_vuart_client.c # Hi3516cv610端USB虚拟串口客户端
└── README.md                      # 本文档
```

## 快速开始

### 1. Air8000端部署

```bash
# 上传代码到Air8000
# 使用LuaTools或其他工具烧录 src/ 目录下的所有.lua文件
# 注意：直接上传src目录中的所有文件，无需保持子目录结构
```

### 2. Hi3516cv610端编译

```bash
# 编译客户端（代码位于 examples/ 目录）
cd examples
arm-himix410-linux-gcc -o vuart_client hi3516cv610_vuart_client.c

# 测试接收
./vuart_client -t

# 查询传感器
./vuart_client -s

# 控制电机
./vuart_client -c 1,1,500  # 电机1正转，速度500
```

## 通信协议

### 协议格式

```
┌─────────┬─────────┬─────────┬──────────────┐
│  CMD    │ LEN_H   │ LEN_L   │    DATA      │
│ (1字节) │ (1字节) │ (1字节) │  (N字节)     │
└─────────┴─────────┴─────────┴──────────────┘
```

### 命令定义

#### 查询命令（Hi3516cv610 → Air8000）

| 命令码 | 名称 | 说明 |
|--------|------|------|
| 0x11 | QUERY_SENSOR | 查询传感器状态 |
| 0x12 | QUERY_MOTOR | 查询电机状态 |
| 0x13 | QUERY_ALL | 查询所有状态 |
| 0x14 | QUERY_NETWORK | 查询网络状态 |

#### 控制命令

| 命令码 | 名称 | 数据格式 | 说明 |
|--------|------|----------|------|
| 0x20 | MOTOR_CTRL | [ID][动作][速度H][速度L] | 电机控制 |
| 0x21 | SET_PARAM | [参数ID][参数值] | 参数设置 |
| 0x40 | GPIO_CTRL | [引脚][值] | GPIO控制 |
| 0x41 | GPIO_QUERY | [引脚] | GPIO状态查询 |

#### 响应命令（Air8000 → Hi3516cv610）

| 命令码 | 名称 | 说明 |
|--------|------|------|
| 0x01 | RESP_SENSOR | 传感器数据响应 |
| 0x02 | RESP_MOTOR | 电机状态响应 |
| 0x04 | RESP_NETWORK | 网络状态响应 |
| 0x05 | RESP_ACK | 确认响应 |
| 0x06 | RESP_GPIO | GPIO状态响应 |
| 0x10 | STATUS_PUSH | 状态推送（主动） |
| 0xFF | RESP_ERROR | 错误响应 |

## 系统架构

```
┌─────────────────────────────────────┐
│       Air8000 (4G模块)              │
│                                     │
│  ┌──────────────┬───────────────┐  │
│  │ USB RNDIS    │ USB VUART_0   │  │
│  │ (网络透传)    │ (命令控制)     │  │
│  └──────┬───────┴───────┬───────┘  │
└─────────┼───────────────┼──────────┘
          │ USB复合设备    │
    ┌─────┴───────────────┴─────┐
    │   Hi3516cv610 (主控板)     │
    │                            │
    │  /dev/wwan0  /dev/ttyACM0  │
    └────────────────────────────┘
```

## 功能特性

✅ **双通道通信** - RNDIS网络 + 虚拟串口
✅ **4G网络共享** - Hi3516cv610通过Air8000上网
✅ **多电机控制** - 支持多个不同CAN ID的DM电机（v2.0新增）
✅ **传感器采集** - 温度、湿度、光照等
✅ **状态推送** - Air8000主动推送状态到Hi3516cv610
✅ **日志过滤** - 协议层自动过滤日志信息

## 配置说明

### 启用DM CAN电机控制（v2.0）

编辑 `src/main.lua`，取消注释电机初始化代码：

```lua
-- ==================== 3.5 初始化DM CAN电机（可选）====================
local dm_motor = require "dm_motor_bridge"
sys.taskInit(function()
    sys.wait(2000)  -- 等待系统稳定
    dm_motor.init()
    -- 注册电机（根据实际使用的CAN ID修改）
    dm_motor.register(0x02)  -- 注册第1个电机，CAN ID: 0x02
    dm_motor.register(0x03)  -- 注册第2个电机，CAN ID: 0x03
end)

-- 取消注释命令处理代码（0x30, 0x31, 0x32, 0x33, 0x18）
```

详细协议请参考 [DM_MOTOR_PROTOCOL.md](docs/protocol/DM_MOTOR_PROTOCOL.md)

### 修改电机数量（普通电机）

编辑 `src/main.lua`:

```lua
-- 根据实际需求配置电机数量
for i = 1, 8 do  -- 改为8个电机
    motor_status[i] = {
        action = 0,
        speed = 0,
    }
end
```

### 禁用模拟数据

编辑 `src/main.lua`，注释掉传感器模拟代码：

```lua
-- 传感器数据模拟（生产环境请删除）
-- sys.timerLoopStart(function()
--     sensor_data.temperature = 20 + math.random(0, 100) / 10
--     ...
-- end, 5000)
```

### 添加DS18B20传感器

编辑 `src/main.lua`，取消注释：

```lua
local ds18b20 = require "ds18b20_sensor"
usb_vuart.on_cmd(0x15, function(data)
    local temp_data = ds18b20.read_temperature_data()
    return pack_response(0x06, temp_data)
end)
```

## 性能指标

| 指标 | 值 |
|------|-----|
| USB版本 | USB 2.0 High Speed |
| 虚拟串口速率 | ~10 MB/s（实际） |
| 命令响应延迟 | < 5ms |
| 网络透传速率 | ~30 MB/s（RNDIS） |
| 当前应用带宽 | ~200 B/s |
| **余量** | **50,000倍** |

## 故障排查

### 1. 找不到ttyACM设备

```bash
# 检查USB设备
lsusb | grep 19D1

# 检查内核日志
dmesg | grep -i "usb\|cdc\|acm"

# 加载驱动
modprobe cdc_acm
```

### 2. 权限不足

```bash
sudo chmod 666 /dev/ttyACM0
```

### 3. 收不到数据

- 确认Air8000已烧录代码
- 尝试其他ttyACM设备（可能是ttyACM1-3）
- 检查USB连接

## 版本历史

- **v3.1.0** (2025.12.13) - **代码结构规范化**
  - ✅ 重构项目目录结构，代码模块化
  - ✅ 源代码迁移到 `src/` 目录
  - ✅ 文档整理到 `docs/` 目录
  - ✅ 添加GPIO控制命令（0x40, 0x41）
- **v3.0.0** (2025.12.13) - **重构DM电机驱动，支持多电机动态控制**
  - ✅ 重构 `dm_can_motor.lua` - 支持多电机面向对象管理
  - ✅ 更新 `dm_motor_bridge.lua` - 适配多电机接口
  - ✅ 更新所有DM电机命令，增加电机ID参数
  - ✅ 支持同时控制多个不同CAN ID的电机
  - ✅ 更新 `DM_MOTOR_PROTOCOL.md` v2.0协议文档
- **v2.1.0** (2025.12.13) - 代码精简，移除测试代码
- **v2.0.0** (2025.12.13) - 支持多电机控制
- **v1.0.0** (2025.12.13) - 初始版本

## 技术支持

详细文档：
- [通信协议](docs/protocol/PROTOCOL.md)
- [DM电机控制协议](docs/protocol/DM_MOTOR_PROTOCOL.md) - **v2.0 多电机支持**
- [客户端使用](docs/guides/README_VUART_CLIENT.md)

---

**项目**: VDM Air8000 双通道通信系统
**版本**: v3.1.0
**日期**: 2025.12.13
