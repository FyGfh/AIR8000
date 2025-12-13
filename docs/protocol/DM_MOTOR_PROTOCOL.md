# DM CAN电机 USB虚拟串口协议（多电机版）

## 概述

本文档描述如何通过USB虚拟串口控制**多个**DM（达妙）CAN电机。Air8000作为CAN总线主机，Hi3516cv610通过USB虚拟串口发送命令来控制不同CAN ID的电机。

**v2.0 更新说明**：
- ✅ 支持多个不同CAN ID的电机
- ✅ 所有命令增加**电机ID参数**
- ✅ 每个电机独立控制和状态查询

## 电机能力

- **控制模式**：
  - MIT模式（阻抗控制）
  - 位置速度模式
  - 速度模式
- **反馈信息**：位置、速度、扭矩、温度、错误码
- **通信速率**：CAN 1Mbps
- **多电机支持**：支持多达255个电机（通过CAN ID区分）

## 电机注册

在使用电机前，需要先在Air8000端注册电机的CAN ID：

```lua
-- main.lua中
dm_motor.register(0x02)  -- 注册CAN ID为0x02的电机
dm_motor.register(0x03)  -- 注册CAN ID为0x03的电机
```

## 命令定义

### 1. DM电机MIT模式控制 (0x30)

**方向**: Hi3516cv610 → Air8000

**数据格式**:
```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 电机ID   │ 位置(4B) │ 速度(4B) │  Kp(4B)  │  Kd(4B)  │ 扭矩(4B) │
│  (1B)    │  float   │  float   │  float   │  float   │  float   │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
总长度: 21字节
```

**参数说明**:
- `电机ID (motor_id)`: 电机CAN ID，与注册时一致
- `位置 (p_des)`: 目标位置 (rad)，范围: -PMAX ~ +PMAX
- `速度 (v_des)`: 目标速度 (rad/s)，范围: -VMAX ~ +VMAX
- `Kp`: 位置刚度系数，范围: 0 ~ 50
- `Kd`: 阻尼系数，范围: 0 ~ 5
- `扭矩 (t_ff)`: 前馈扭矩 (Nm)，范围: -TMAX ~ +TMAX

**响应**: 0x05 (ACK)

**示例（C）**:
```c
uint8_t motor_id = 0x02;  // 控制CAN ID为0x02的电机
float p_des = 0.5;        // 目标位置 0.5 rad
float v_des = 2.0;        // 目标速度 2.0 rad/s
float kp = 10.0;          // 刚度
float kd = 0.5;           // 阻尼
float t_ff = 0.0;         // 前馈扭矩

uint8_t cmd[24];
cmd[0] = 0x30;            // 命令码
cmd[1] = 0x00;            // LEN_H
cmd[2] = 0x15;            // LEN_L = 21

cmd[3] = motor_id;        // 电机ID
memcpy(&cmd[4], &p_des, 4);
memcpy(&cmd[8], &v_des, 4);
memcpy(&cmd[12], &kp, 4);
memcpy(&cmd[16], &kd, 4);
memcpy(&cmd[20], &t_ff, 4);

write(uart_fd, cmd, 24);
```

---

### 2. DM电机位置速度模式控制 (0x31)

**方向**: Hi3516cv610 → Air8000

**数据格式**:
```
┌──────────┬──────────┬──────────┐
│ 电机ID   │ 位置(4B) │ 速度(4B) │
│  (1B)    │  float   │  float   │
└──────────┴──────────┴──────────┘
总长度: 9字节
```

**参数说明**:
- `电机ID (motor_id)`: 电机CAN ID
- `位置 (p_des)`: 目标位置 (rad)
- `速度 (v_des)`: 目标速度 (rad/s)

**响应**: 0x05 (ACK)

**示例（C）**:
```c
uint8_t motor_id = 0x02;
float p_des = 1.0;   // 1 rad
float v_des = 5.0;   // 5 rad/s

uint8_t cmd[12];
cmd[0] = 0x31;
cmd[1] = 0x00;
cmd[2] = 0x09;  // 9字节数据

cmd[3] = motor_id;
memcpy(&cmd[4], &p_des, 4);
memcpy(&cmd[8], &v_des, 4);

write(uart_fd, cmd, 12);
```

---

### 3. DM电机速度模式控制 (0x32)

**方向**: Hi3516cv610 → Air8000

**数据格式**:
```
┌──────────┬──────────┐
│ 电机ID   │ 速度(4B) │
│  (1B)    │  float   │
└──────────┴──────────┘
总长度: 5字节
```

**参数说明**:
- `电机ID (motor_id)`: 电机CAN ID
- `速度 (v_des)`: 目标速度 (rad/s)

**响应**: 0x05 (ACK)

**示例（C）**:
```c
uint8_t motor_id = 0x03;  // 控制电机0x03
float v_des = 10.0;       // 10 rad/s

uint8_t cmd[8];
cmd[0] = 0x32;
cmd[1] = 0x00;
cmd[2] = 0x05;

cmd[3] = motor_id;
memcpy(&cmd[4], &v_des, 4);

write(uart_fd, cmd, 8);
```

---

### 4. DM电机使能控制 (0x33)

**方向**: Hi3516cv610 → Air8000

**数据格式**:
```
┌──────────┬──────────┬──────────┐
│ 电机ID   │ 使能(1B) │ 模式(1B) │
│  (1B)    │          │          │
└──────────┴──────────┴──────────┘
总长度: 3字节
```

**参数说明**:
- `电机ID (motor_id)`: 电机CAN ID
- `使能`: 0=失能, 1=使能
- `模式`: 1=MIT模式, 2=位置速度模式, 3=速度模式

**响应**: 0x05 (ACK)

**示例（C）**:
```c
// 使能电机0x02的MIT模式
uint8_t cmd[] = {0x33, 0x00, 0x03, 0x02, 0x01, 0x01};
write(uart_fd, cmd, 6);

// 失能电机0x03
uint8_t cmd2[] = {0x33, 0x00, 0x03, 0x03, 0x00, 0x01};
write(uart_fd, cmd2, 6);
```

---

### 5. DM电机状态查询 (0x18)

**方向**: Hi3516cv610 → Air8000

**请求数据格式**:
```
┌──────────┐
│ 电机ID   │
│  (1B)    │
└──────────┘
总长度: 1字节
```

**响应**: 0x09

**响应数据格式**:
```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 位置(4B) │ 速度(4B) │ 扭矩(4B) │ MOS温度  │ 转子温度 │ 错误码   │  模式    │  使能    │
│  float   │  float   │  float   │  (1B)    │  (1B)    │  (1B)    │  (1B)    │  (1B)    │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
总长度: 17字节
```

**数据说明**:
- `位置`: 当前位置 (rad)
- `速度`: 当前速度 (rad/s)
- `扭矩`: 当前扭矩 (Nm)
- `MOS温度`: MOS管温度 (°C)
- `转子温度`: 电机转子温度 (°C)
- `错误码`: 0=失能, 1=使能, 8=欠压, 9=过压, 0xA=过流, 0xB=MOS过温, 0xC=线圈过温, 0xD=通讯丢失, 0xE=过载
- `模式`: 1=MIT, 2=位置速度, 3=速度
- `使能`: 0=未使能, 1=已使能

**示例（C）**:
```c
// 查询电机0x02的状态
uint8_t cmd[] = {0x18, 0x00, 0x01, 0x02};
write(uart_fd, cmd, 4);

// 接收响应
uint8_t rx_buf[20];
read(uart_fd, rx_buf, 20);

// 解析数据
if (rx_buf[0] == 0x09) {
    float position, velocity, torque;
    memcpy(&position, &rx_buf[3], 4);
    memcpy(&velocity, &rx_buf[7], 4);
    memcpy(&torque, &rx_buf[11], 4);

    uint8_t temp_mos = rx_buf[15];
    uint8_t temp_rotor = rx_buf[16];
    uint8_t error_code = rx_buf[17];
    uint8_t mode = rx_buf[18];
    uint8_t enabled = rx_buf[19];

    printf("电机0x02状态：\n");
    printf("  位置: %.3f rad\n", position);
    printf("  速度: %.3f rad/s\n", velocity);
    printf("  扭矩: %.3f Nm\n", torque);
    printf("  MOS温度: %d °C\n", temp_mos);
    printf("  转子温度: %d °C\n", temp_rotor);
    printf("  错误码: 0x%02X\n", error_code);
    printf("  模式: %d\n", mode);
    printf("  使能: %d\n", enabled);
}
```

---

## 多电机控制示例

### 同时控制两个电机

```c
// 打开串口
int fd = open("/dev/ttyACM0", O_RDWR);

// 使能电机0x02（MIT模式）
uint8_t enable_cmd1[] = {0x33, 0x00, 0x03, 0x02, 0x01, 0x01};
write(fd, enable_cmd1, 6);
usleep(100000);

// 使能电机0x03（速度模式）
uint8_t enable_cmd2[] = {0x33, 0x00, 0x03, 0x03, 0x01, 0x03};
write(fd, enable_cmd2, 6);
usleep(100000);

// 控制电机0x02（MIT模式）
uint8_t cmd1[24] = {0x30, 0x00, 0x15, 0x02};  // motor_id=0x02
float p1 = 0.0, v1 = 5.0, kp = 10.0, kd = 0.5, t = 0.0;
memcpy(&cmd1[4], &p1, 4);
memcpy(&cmd1[8], &v1, 4);
memcpy(&cmd1[12], &kp, 4);
memcpy(&cmd1[16], &kd, 4);
memcpy(&cmd1[20], &t, 4);
write(fd, cmd1, 24);

// 控制电机0x03（速度模式）
uint8_t cmd2[8] = {0x32, 0x00, 0x05, 0x03};  // motor_id=0x03
float v2 = 10.0;
memcpy(&cmd2[4], &v2, 4);
write(fd, cmd2, 8);

// 查询电机0x02状态
uint8_t query1[] = {0x18, 0x00, 0x01, 0x02};
write(fd, query1, 4);
uint8_t rx1[20];
read(fd, rx1, 20);

// 查询电机0x03状态
uint8_t query2[] = {0x18, 0x00, 0x01, 0x03};
write(fd, query2, 4);
uint8_t rx2[20];
read(fd, rx2, 20);

// 停止所有电机
uint8_t disable1[] = {0x33, 0x00, 0x03, 0x02, 0x00, 0x01};
uint8_t disable2[] = {0x33, 0x00, 0x03, 0x03, 0x00, 0x03};
write(fd, disable1, 6);
write(fd, disable2, 6);
```

---

## Air8000端配置

在 `main.lua` 中启用DM电机支持：

```lua
-- 1. 取消注释初始化代码
local dm_motor = require "dm_motor_bridge"
sys.taskInit(function()
    sys.wait(2000)
    dm_motor.init()

    -- 注册电机（根据实际CAN ID修改）
    dm_motor.register(0x02)
    dm_motor.register(0x03)
end)

-- 2. 取消注释命令处理代码（0x30, 0x31, 0x32, 0x33, 0x18）
```

---

## 错误码说明

| 错误码 | 含义 | 说明 |
|--------|------|------|
| 0x00 | 失能 | 电机未使能 |
| 0x01 | 使能 | 电机正常运行 |
| 0x08 | 欠压 | 供电电压过低 |
| 0x09 | 过压 | 供电电压过高 |
| 0x0A | 过流 | 电流超限 |
| 0x0B | MOS过温 | MOS管温度过高 |
| 0x0C | 线圈过温 | 电机线圈温度过高 |
| 0x0D | 通讯丢失 | CAN通讯超时 |
| 0x0E | 过载 | 负载过大 |

---

## 注意事项

1. **float格式**: 所有浮点数使用**小端序**（Little-Endian）IEEE 754格式
2. **电机ID**: 必须与Air8000端注册的CAN ID一致
3. **参数范围**:
   - 位置: ±PMAX (默认 ±12.5 rad)
   - 速度: ±VMAX (默认 ±280 rad/s)
   - 扭矩: ±TMAX (默认 ±1 Nm)
4. **使能顺序**: 先使能电机，再发送控制命令
5. **失能延迟**: 失能后建议等待至少100ms再关闭电源
6. **故障处理**: 检测到错误码非0x00/0x01时，应停止控制并检查硬件
7. **多电机控制**: 每个电机可独立使用不同控制模式

---

## 版本信息

- **文档版本**: v2.0
- **日期**: 2025.12.13
- **适用电机**: DM系列CAN总线伺服电机
- **更新内容**:
  - ✅ 支持多电机控制
  - ✅ 所有命令增加电机ID参数
  - ✅ 新增多电机控制示例
