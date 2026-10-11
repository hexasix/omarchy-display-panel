# Display Layout

Omarchy 状态栏的显示器面板,在官方 Display 面板基础上补了两件事:

- **主显示器** —— 指定哪块屏是"主屏",工作区 1 永远待在它上面
- **显示器排列** —— 指定每块屏在另一块屏的哪一侧

解决的具体问题:笔记本外接显示器时,用 `SUPER + CTRL + DELETE` 把笔记本内屏重新打开,Hyprland 会把**工作区 1 连同上面的窗口一起拽到笔记本屏上**,焦点也跟着跑,外接屏被丢在一个空工作区里。

顺带修了官方面板的一个 bug:面板里"显示器"那几行的开关一直是坏的(见下面「关于 `hyprctl keyword`」)。

## 要求

- Hyprland 0.55 或更新版本,使用 **Lua 配置**(`monitors.lua` / `hyprland.lua` 那套)。老式的 `.conf` 配置不适用。
- Omarchy。

## 安装

```bash
git clone <这个仓库> ~/Documents/omarchy-display-panel
~/Documents/omarchy-display-panel/install.sh
```

`install.sh` 是幂等的(可以反复运行),做四件事:

1. 把插件文件复制到 `~/.config/omarchy/plugins/delin.monitor/`
2. 如果 `~/.config/hypr/display-layout.lua` 不存在就创建它
3. 往 `~/.config/hypr/hyprland.lua` 里加一行 `require("hypr.display-layout")`(会先备份)
4. 重载配置并重启 shell

也可以用 Omarchy 自己的方式装(但**不会**帮你做第 2、3 步):

```bash
omarchy plugin add <仓库地址> --enable
```

> 第 3 步不能省。少了那行 `require`,面板照常写文件、也不报错,但规则**永远不会被读取** —— 这正是 Omarchy 仓库里那个 issue #9422 的成因。

## 使用

面板在状态栏上叫 **Display Layout**,快捷键 `SUPER + CTRL + D`。

| 区域 | 作用 |
|---|---|
| BRIGHTNESS | 亮度 |
| TEXT SIZE | 界面文字大小 |
| SCALE | 当前聚焦屏的缩放 |
| **MAIN DISPLAY** | 选主屏 |
| DISPLAYS | 每块屏的开关 + **Position** 下拉 |

**改主屏**:在 MAIN DISPLAY 里选一块屏。工作区 1 和焦点立刻跟过去,并写进配置。

**改排列**:每块屏下面的 Position 下拉 —— `Main · 0x0` 是坐标原点,其余是"在 DP-1 的右边"这类相对位置。**键盘也可以用**:`j`/`k` 选中某块屏那一行,按 `h`/`l` 循环切换它的位置。

两个附带行为:

- **关掉主屏会自动交接** —— 如果你要关的屏正好是主屏,面板先把主屏交给另一块屏再关,不会让窗口滞留在黑掉的屏上。
- **笔记本内屏的开关走 Omarchy 自己的机制**,所以和 `SUPER + CTRL + DELETE` 完全同步,重启后也还记得。

### 命令行

```bash
omarchy-shell omarchy.monitor main                       # 查当前主屏
omarchy-shell omarchy.monitor setMain eDP-1              # 设主屏
omarchy-shell omarchy.monitor arrangement                # 查所有屏的位置
omarchy-shell omarchy.monitor position eDP-1 auto-left   # 设某块屏的位置
omarchy-shell omarchy.monitor toggleDisplay eDP-1        # 开关某块屏
omarchy-shell omarchy.monitor state                      # 完整状态 JSON
```

位置取值:`0x0`、`auto-left`、`auto-right`、`auto-up`、`auto-down`。

## 它写哪些文件

| 路径 | 内容 |
|---|---|
| `~/.config/omarchy/plugins/delin.monitor/` | 插件本体,Omarchy 更新不会覆盖 |
| `~/.config/hypr/display-layout.lua` | **自动生成**,主屏规则 + 排列规则。别手改,面板每次变更会整体重写 |
| `~/.config/hypr/hyprland.lua` | 只加了一行 `require` |

`monitors.lua` **没有**被改动 —— Omarchy 自己会用 `sed` 去改那个文件(`omarchy-hyprland-monitor-scaling`),把手写规则混进去早晚会打架。

## 开发

改完这里的源码,跑 `./install.sh` 同步到运行中的副本,然后 **`omarchy restart shell`**。

重启那步不能省:存盘只会热重载文件,状态栏组件是缓存的,新加的界面元素不会出现,日志里却什么错都不报。排查时看:

```bash
journalctl --user -n 100 --no-pager | grep -i qml
```

## 一些踩过的坑

**关于 `hyprctl keyword`**:Hyprland 的 Lua 配置解析器下,`hyprctl keyword monitor ...` 直接失效 —— 报 `keyword can't work with non-legacy parsers. Use eval.`,而且**静默不生效**。官方 Display 面板就是用这种写法,所以它的显示器开关一直是坏的。本插件改用 `hyprctl eval`。

**Monitor 规则是整体替换**:`hl.monitor({...})` 里漏写的字段不会继承上一个规则。只写 `position` 不写 `scale`,Hyprland 会自己给那块屏挑一个缩放(实测 4K 屏从 2 变成 1.5)。所以生成的规则里 `mode` 和 `scale` 都显式写明。

**为什么用 `auto-left` 而不是算好的像素坐标**:相对位置由 Hyprland 在加载时按当前布局解析,缩放变化后不会失效;写死的像素偏移会。

## 已知限制

- 排列界面按"相对位置"表达,超过两块屏时方向列表只给出第一块其他屏的名字 —— `auto-*` 本身不带第二个屏的名字,多列几组也只会生成同样四个字符串。
- 面板的鼠标点击和键盘操作是在真机上验证的,但**自动化测试只覆盖到 IPC 层**(`omarchy-shell omarchy.monitor ...`),底下的 `setMainDisplay` / `setPosition` 和界面调用的是同一个函数。

## License

MIT
