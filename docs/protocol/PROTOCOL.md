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
| 0x31 | 0x3100-0x31FF | MOTOR_PARAM | 电机参数读写 |
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

## 0x31 电机参数命令组

用于读写DM电机内部寄存器参数，支持参数持久化。

### 命令列表

| CMD | 名称 | DATA格式 | 响应格式 | 说明 |
|-----|------|----------|----------|------|
| 0x3101 | MOTOR_READ_REG | [motor_id u8][reg_id u8] | [motor_id u8][reg_id u8][value f32] | 读取寄存器 |
| 0x3102 | MOTOR_WRITE_REG | [motor_id u8][reg_id u8][value f32] | [motor_id u8][reg_id u8] | 写入寄存器 |
| 0x3103 | MOTOR_SAVE_FLASH | [motor_id u8] | [motor_id u8] | 保存参数到Flash |
| 0x3104 | MOTOR_REFRESH | [motor_id u8] | [motor_id u8][pos f32][vel f32][torque f32][temp_mos u8][temp_rotor u8][error u8][enabled u8] | 刷新电机状态 |
| 0x3105 | MOTOR_CLEAR_ERROR | [motor_id u8] | [motor_id u8] | 清除电机错误 |

### 寄存器地址表

| 地址 | 名称 | 类型 | 读写 | 说明 |
|------|------|------|------|------|
| 0x00 | UV_Value | float | RW | 低压保护值 |
| 0x01 | KT_Value | float | RW | 扭矩系数 |
| 0x02 | OT_Value | float | RW | 过温保护值 |
| 0x03 | OC_Value | float | RW | 过流保护值 |
| 0x04 | ACC | float | RW | 加速度 |
| 0x05 | DEC | float | RW | 减速度 |
| 0x06 | MAX_SPD | float | RW | 最大速度 |
| 0x07 | MST_ID | u32 | RW | 反馈ID (Master ID) |
| 0x08 | ESC_ID | u32 | RW | 接收ID (Slave ID) |
| 0x09 | TIMEOUT | u32 | RW | 超时警报时间 |
| 0x0A | CTRL_MODE | u32 | RW | 控制模式 |
| 0x15 | PMAX | float | RW | 位置映射范围 (rad) |
| 0x16 | VMAX | float | RW | 速度映射范围 (rad/s) |
| 0x17 | TMAX | float | RW | 扭矩映射范围 (Nm) |
| 0x18 | I_BW | float | RW | 电流环控制带宽 |
| 0x19 | KP_ASR | float | RW | 速度环Kp |
| 0x1A | KI_ASR | float | RW | 速度环Ki |
| 0x1B | KP_APR | float | RW | 位置环Kp |
| 0x1C | KI_APR | float | RW | 位置环Ki |
| 0x1D | OV_Value | float | RW | 过压保护值 |
| 0x50 | p_m | float | RO | 电机当前位置 (rad) |
| 0x51 | v_m | float | RO | 电机当前速度 (rad/s) |
| 0x52 | t_m | float | RO | 电机当前扭矩 (Nm) |

### 示例：读取电机1的位置环Kp

```
请求帧:
  CMD    = 31 01 (MOTOR_READ_REG)
  LEN    = 00 02 (2字节)
  DATA   = 01 1B
           │  └─ reg_id=0x1B (KP_APR)
           └───── motor_id=1

完整帧:
AA 55 10 00 01 31 01 00 02 01 1B [CRC_H] [CRC_L]

响应帧:
AA 55 10 01 01 31 01 00 06 01 1B 41200000 [CRC]
                              │  │  └─ value=10.0 (f32大端序)
                              │  └───── reg_id=0x1B
                              └──────── motor_id=1
```

### 示例：设置电机1的位置环Kp为15.0

```
请求帧:
  CMD    = 31 02 (MOTOR_WRITE_REG)
  LEN    = 00 06 (6字节)
  DATA   = 01 1B 41700000
           │  │  └─ value=15.0 (f32大端序)
           │  └───── reg_id=0x1B (KP_APR)
           └──────── motor_id=1

完整帧:
AA 55 10 00 01 31 02 00 06 01 1B 41 70 00 00 [CRC_H] [CRC_L]

响应帧 (成功):
AA 55 10 01 01 31 02 00 02 01 1B [CRC]
```

### 注意事项

1. **写入寄存器前必须先失能电机**
2. **写入后需调用 0x3103 保存到Flash才能掉电保存**
3. **寄存器值使用大端序 f32 格式**
4. **只读寄存器(RO)写入会失败**

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
| 0x0006 | SYS_HB_WDT_CONFIG | [enable u8][timeout_sec u16][power_off_sec u8] | 心跳看门狗配置 |
| 0x0007 | SYS_HB_WDT_STATUS | - | 心跳看门狗状态查询 |
| 0x0008 | SYS_HB_POWEROFF | NOTIFY: [reset_count u8] | 断电前通知 (MCU→Hi3516) |
| 0x0010 | SYS_SET_RTC | [year u16][mon u8][day u8][hour u8][min u8][sec u8] | 设置RTC |
| 0x0011 | SYS_GET_RTC | - | 获取RTC |
| 0x0020 | SYS_TEMP_CTRL | [enable u8][target_temp i16] | 温控设置 |

---

## 心跳看门狗 (Heartbeat Watchdog)

心跳看门狗用于监控 Hi3516cv610 的运行状态。当 MCU 长时间未收到心跳时，会通过 GPIO 断电重启 Hi3516cv610。

### 工作流程

```
Hi3516cv610                                    Air8000 (MCU)
    │                                               │
    │  SYS_HB_WDT_CONFIG (启用看门狗)                │
    │ ─────────────────────────────────────────────→│ 开始计时
    │                ACK                            │
    │ ←─────────────────────────────────────────────│
    │                                               │
    │  SYS_PING (心跳)                              │
    │ ─────────────────────────────────────────────→│ 重置计时器
    │                ACK                            │
    │ ←─────────────────────────────────────────────│
    │                                               │
    ├──── 定期发送心跳 (建议60秒间隔) ────┤          │
    │                                               │
    ╳  Hi3516 崩溃，停止发送心跳                     │
    │                                               │
    │                                               │ 超时检测
    │                                               │
    │  SYS_HB_POWEROFF (NOTIFY)                     │
    │ ←─────────────────────────────────────────────│ 通知优雅关机
    │                                               │
    │  (Hi3516 执行 sync && poweroff)               │ 等待5秒
    │                                               │
    │                                               │ GPIO断电
    ├──── 断电2秒 ─────┤                            │
    │                                               │ GPIO上电
    │  (Hi3516 重新启动)                             │
    │                                               │
```

### 0x0006 SYS_HB_WDT_CONFIG - 心跳看门狗配置

**请求数据格式:**

| 字段 | 偏移 | 长度 | 说明 |
|------|------|------|------|
| enable | 0 | 1 | 0=禁用, 1=启用 |
| timeout_sec | 1 | 2 | 超时时间(秒), 大端序, 范围: 10-3600 |
| power_off_sec | 3 | 1 | 断电持续时间(秒), 范围: 1-30 |

**响应:** ACK (成功) 或 NACK (参数错误)

**示例: 启用看门狗，超时480秒(8分钟)，断电2秒**

```
请求帧:
AA 55 10 00 [SEQ] 00 06 00 04 01 01 E0 02 [CRC]
                              │  │     │
                              │  │     └─ power_off_sec=2
                              │  └─────── timeout_sec=480 (0x01E0, 大端序)
                              └────────── enable=1

响应帧 (成功):
AA 55 10 03 [SEQ] 00 06 00 00 [CRC]
```

### 0x0007 SYS_HB_WDT_STATUS - 心跳看门狗状态查询

**请求数据:** 无

**响应数据格式:**

| 字段 | 偏移 | 长度 | 说明 |
|------|------|------|------|
| enable | 0 | 1 | 当前状态: 0=禁用, 1=启用 |
| timeout_sec | 1 | 2 | 配置的超时时间(秒), 大端序 |
| power_off_sec | 3 | 1 | 配置的断电持续时间(秒) |
| remaining_sec | 4 | 2 | 距离超时剩余时间(秒), 大端序 |
| reset_count | 6 | 1 | 累计复位次数 (0-255 循环) |

**示例: 查询状态**

```
请求帧:
AA 55 10 00 [SEQ] 00 07 00 00 [CRC]

响应帧:
AA 55 10 01 [SEQ] 00 07 00 07 01 01 E0 02 01 68 03 [CRC]
                              │  │     │  │     │
                              │  │     │  │     └─ reset_count=3
                              │  │     │  └─────── remaining_sec=360 (0x0168)
                              │  │     └────────── power_off_sec=2
                              │  └──────────────── timeout_sec=480 (0x01E0)
                              └─────────────────── enable=1
```

### 0x0008 SYS_HB_POWEROFF - 断电前通知 (NOTIFY)

当心跳超时即将断电时，MCU 会发送此通知给 Hi3516cv610，让其有机会执行优雅关机。

**方向:** Air8000 (MCU) → Hi3516cv610

**数据格式:**

| 字段 | 偏移 | 长度 | 说明 |
|------|------|------|------|
| reset_count | 0 | 1 | 即将执行的复位次数 |

**示例:**

```
NOTIFY帧:
AA 55 10 02 00 00 08 00 01 03 [CRC]
         │  │              └─ reset_count=3
         │  └───────────────── SEQ=00 (通知不需要响应)
         └──────────────────── TYPE=NOTIFY

Hi3516cv610 收到后应执行:
$ sync && poweroff
```

**注意:** 收到此通知后，Hi3516cv610 有约5秒时间执行关机操作，之后 MCU 将切断电源。

### 0x0001 SYS_PING - 心跳

复用现有的 PING 命令作为心跳信号。

**请求数据:** 无
**响应:** ACK

**示例:**

```
请求帧:
AA 55 10 00 [SEQ] 00 01 00 00 [CRC]

响应帧:
AA 55 10 03 [SEQ] 00 01 00 00 [CRC]
```

### Hi3516cv610 端实现建议

```c
#include "protocol.h"
#include <pthread.h>
#include <unistd.h>
#include <signal.h>

static int uart_fd = -1;
static volatile int running = 1;

// POWEROFF通知处理
void handle_poweroff_notify(uint8_t reset_count) {
    printf("收到POWEROFF通知，复位次数: %d\n", reset_count);
    printf("执行优雅关机...\n");
    system("sync");
    system("poweroff");
}

// 心跳发送线程
void* heartbeat_thread(void* arg) {
    uint8_t frame[32];
    static uint8_t seq = 0;

    while (running) {
        // 构造心跳帧
        int len = build_request(frame, seq++, CMD_SYS_PING, NULL, 0);
        write(uart_fd, frame, len);

        // 等待60秒 (建议心跳间隔 = 超时时间 / 8)
        sleep(60);
    }
    return NULL;
}

// 配置心跳看门狗
int configure_heartbeat_watchdog(uint8_t enable, uint16_t timeout_sec, uint8_t power_off_sec) {
    uint8_t frame[32];
    uint8_t data[4];

    data[0] = enable;
    data[1] = (timeout_sec >> 8) & 0xFF;  // 大端序高字节
    data[2] = timeout_sec & 0xFF;         // 大端序低字节
    data[3] = power_off_sec;

    int len = build_request(frame, 0, CMD_SYS_HB_WDT_CONFIG, data, 4);
    write(uart_fd, frame, len);

    // 等待ACK响应...
    return 0;
}

// 主函数示例
int main() {
    uart_fd = open("/dev/ttyACM0", O_RDWR);

    // 配置串口...

    // 配置看门狗: 启用, 超时480秒(8分钟), 断电2秒
    configure_heartbeat_watchdog(1, 480, 2);

    // 启动心跳线程
    pthread_t tid;
    pthread_create(&tid, NULL, heartbeat_thread, NULL);

    // 接收处理循环
    while (running) {
        uint8_t frame[256];
        int len = read_frame(uart_fd, frame, sizeof(frame));
        if (len > 0) {
            uint8_t type = frame[3];
            uint16_t cmd = (frame[5] << 8) | frame[6];

            // 检查是否是POWEROFF通知
            if (type == TYPE_NOTIFY && cmd == CMD_SYS_HB_POWEROFF) {
                handle_poweroff_notify(frame[9]);
            }
        }
    }

    return 0;
}
```

### 配置建议

| 参数 | 建议值 | 说明 |
|------|--------|------|
| timeout_sec | 480 (8分钟) | 超时时间，根据应用场景调整 |
| power_off_sec | 2 | 断电持续时间，通常2秒足够 |
| 心跳间隔 | 60秒 | 建议设置为超时时间的 1/8 |
| grace_period | 5秒 (固定) | POWEROFF通知后等待时间 |

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
| 0x0006 | SYS_HB_WDT_CONFIG |
| 0x0007 | SYS_HB_WDT_STATUS |
| 0x0008 | SYS_HB_POWEROFF |
| 0x3001 | MOTOR_ROTATE |
| 0x3002 | MOTOR_ENABLE |
| 0x3006 | MOTOR_GET_POS |
| 0x3101 | MOTOR_READ_REG |
| 0x3102 | MOTOR_WRITE_REG |
| 0x3103 | MOTOR_SAVE_FLASH |
| 0x3104 | MOTOR_REFRESH |
| 0x3105 | MOTOR_CLEAR_ERROR |
| 0x4001 | SENSOR_READ_TEMP |
| 0x5001 | DEV_HEATER |
| 0x5006 | DEV_MOTOR_POWER |

---
