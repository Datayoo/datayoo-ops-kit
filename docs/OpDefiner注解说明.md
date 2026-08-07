# OpDefiner 注解说明文档

## 一、概述

`OpDefiner` 是用于定义算子（Operator）元信息的核心注解。通过该注解可以声明算子的名称、类型、端口、参数、可视化组件等全部描述信息。算子打包插件将读取该信息完成算子的打包。

---

## 二、属性详解

### 1. 基础标识信息

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `name` | `String` | （必填） | 算子的名字，唯一标识一个算子类型 |
| `type` | `String` | （必填） | 算子的类型，包括：输入(Input)，输出(Output)，读取(Reader)，写出(Writer)，处理(Processing)，分析(Analysis)，控制(Control)，资源(ResMan)，行为(Action)等 |
| `portrait` | `String` | `""` | 算子的头像图标资源路径 |
| `version` | `String` | `"0.1"` | 算子版本号 |
| `edition` | `String` | `""` | 版本类别/发行版标识，可用于区分社区版、企业版等 |
| `provider` | `String` | `"DataYoo"` | 算子的提供方 |
| `summary` | `String` | `""` | 算子的简介说明 |

### 2. 框架与运行模式

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `computionFramework` | `String` | `"sengee"` | 算子依赖的计算框架名。Descriptor算子的计算框架名为“sengee”；Oyez算子所的计算框架名“oyez” |
| `atom`               | `boolean` | `true`     | 是否为原子算子。`true` 表示算子拥有独立功能；`false` 表示容器算子，容器算子内部可以定义子功能逻辑。 |

### 3. 标签与分组

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `tags` | `TagPair[]` | `{}` | 算子的标签键值对集合，用于分类、检索和过滤。比如：opCats="stream"，且其type属性为Input，表示算子在“输入/文件输入”分组下。 |
| `lattices` | `String[]` | `{}` | 算子晶格。若容器算子内部需要几个不同的空间，隔离不同的功能逻辑。通过晶格进行划分。比如：{"train","test"}，表示一个是训练区；一个是预测区。 |

### 4. 端口定义

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `inputPorts` | `Port[]` | （必填） | 输入端口列表，定义算子接收数据的入口 |
| `outputPorts` | `Port[]` | （必填） | 输出端口列表，定义算子输出数据的出口 |

### 5. 参数信息

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `parameters` | `String` | `""` | 算子的参数信息，遵循 `configx` 规范进行描述 |

### 6. 复合组件

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `compoxes` | `Compox[]` | `{}` | 算子内部的复合组件（Controller/组件）定义列表，用于复杂算子的可视化与交互描述 |

---

## 三、关联注解说明

### 3.1 Port（端口）

定义算子的输入/输出端口。

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `name` | `String` | （必填） | 端口名 |
| `type` | `PortType` | `PortType.THROUGH` | 端口类型（如 THROUGH 直通）；下面两种类型，仅容器算子会用到。PortType.INTERNAL，表示端口仅在容器算子内部可见；PortType.EXTERNAL，表示端口仅在容器算子外可见。 |
| `flowDataType` | `String` | （必填） | 端口流转的数据类型。数据类型采用层级表达模式，必须以“/”开始，“/”表示任何数据类型。“/dataStream”表示数据流类型。“/dataStream”是“/”类型的子类型。系统将比较端口间的数据类型判断两个端口是否可以建立连接。若输出端口为“/dataStream”，输入端口为“/”, 端口可连接；若反过来，则不可连接。 |
| `connectionLimit` | `int`       | `-1`               | 连接数限制，`-1` 表示不限制                                  |
| `lattice`         | `String`    | `""`               | 端口所属晶格                                                 |
| `option`          | `boolean`   | `false`            | 是否为可选端口                                               |
| `extendable`      | `boolean`   | `false`            | 端口是否可扩展（动态增加），比如：条件分支算子，端口可动态扩展。 |
| `tags`            | `TagPair[]` | `{}`               | 端口标签                                                     |

### 3.2 TagPair（标签键值对）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `name` | `String` | （必填） | Tag 的名字，如：opCats |
| `value` | `String` | （必填） | Tag 的值,  如：stream |

### 3.3 Compox（UI组件）

用于描述算子内部的可视化组件。

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `String` | （必填） | 组件唯一 ID |
| `parentId` | `String` | （必填） | 父组件或父 Compox 的 ID |
| `type` | `String` | `"sightx-input"` | 组件类型, 参见... |
| `attributes` | `String` | `""` | 可视化属性信息 |
| `dataDescriptor`     | `DataDesc`      |                  | 单个数据描述符          |
| `dataDescriptors`    | `DataDesc[]`    | `{}`             | 多个数据描述符列表      |
| `visibleDescriptors` | `VisibleDesc[]` | `{}`             | 可见性描述符列表        |
| `actionDescriptors`  | `ActionDesc[]`  | `{}`             | 行为描述符列表          |

### 3.4 DataDesc（数据描述）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `defaultValue` | `String` | `""` | 默认值 |
| `data`         | `String`         | `""`                | 数据内容，Json格式                           |
| `actionScript` | `String`         | `""`                | 动作脚本，JavaScript。通过执行脚本获取数据。 |
| `constraint`   | `DataConstraint` | `@DataConstraint()` | 数据约束                                     |

### 3.5 DataConstraint（数据约束）（待补充）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `constraintType` | `String` | `""` | 约束类型 |
| `properties` | `String` | `"{}"` | 约束属性，JSON 格式 |

### 3.6 VisibleDesc（可见性描述）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `visibleType` | `VisibleType` | （必填） | 可见性类型。VisibleType.VISIBLE表示是否可见；VisibleType.EDITABLE表示是否可编辑。 |
| `condition` | `String` | `""` | 可见性条件表达式，语法参见：https://gitee.com/mirrors_joewalnes/filtrex |

### 3.7 ActionDesc（行为描述）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `sightxEvent` | `SightxEvent` | （必填） | 触发的 Sightx 事件。 |
| `actionScript` | `String` | `""` | 动作脚本，JavaScript |

### 3.8 SightxEvent（Sightx 事件）

| 属性 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `sightxEventType` | `SightxEventType` | （必填） | 事件类型。CLICK：单击；DCLICK：双击；VCHANGE：值变更；LOAD：页面装载 |

---

## 四、属性分类总览

```
OpDefiner
├── 基础信息：name, type, portrait, version, edition, provider, summary
├── 框架与运行：computionFramework, stackMode, atom, breaker, templatable, replica
├── 分组标签：tags, lattices
├── 端口：inputPorts, outputPorts
├── 参数：parameters
├── 复合组件：compoxes
    ├── dataDescriptor / dataDescriptors (DataDesc)
    │   └── constraint (DataConstraint)
    ├── visibleDescriptors (VisibleDesc)
    └── actionDescriptors (ActionDesc)
        └── sightxEvent (SightxEvent)
```

---

## 五、使用示例

```java
@OpDefiner(name = "JsonFlatter",
    type = OperatorProfileConstants.OC_PROCESS,
    version = "1.0",
    portrait = "",
    computionFramework = "sengee",
    tags = { @TagPair(name = SengeeConstants.TAG_OP_CATS, value = "rowset,flat")
    },
    inputPorts = { @Port(name = SengeeOperatorConstants.PORT_DATA_IN,
        flowDataType = SengeeConstants.FDT_ANY,
        option = true)
    },
    outputPorts = { @Port(name = SengeeOperatorConstants.PORT_DATA_OUT,
        flowDataType = SengeeConstants.FDT_ANY,
        option = true)
    },
    parameters =
        "<parameters><parametergroup name=\"general\" c_Alias=\"一般\" c_Compox=\"sightx-tab\">"
            + "<parameter name=\"dataColumn\" c_Alias=\"Json数据列\" c_Compox=\"sengee-string-column-selector\"></parameter>"
            + "<parametergroup name=\"structureMappings\" c_Alias=\"结构映射\" c_Compox=\"sengee-self-structureMappings\"  c_AutoMapping=\"true\">"
            + "<parameter name=\"dataExample\" c_Alias=\"数据样例\" c_Compox=\"sengee-json-sample\"></parameter>"
            + "<parameter name=\"mappingName\" c_Alias=\"字段映射名\">o</parameter>"
            + "<parameter name=\"dataPath\" c_Alias=\"结构字段路径\">o</parameter>"
            + "<parameter name=\"filterMode\" c_Alias=\"过滤模式\" c_Compox=\"filterModeCtrl\">filter</parameter>"
            + "<parameter name=\"startPos\" c_Alias=\"起始位置\" c_Compox=\"startPosCtrl\">0</parameter>"
            + "<parameter name=\"endPos\" c_Alias=\"结束位置\" c_Compox=\"endPosCtrl\">-1</parameter>"
            + "<parameter name=\"filter\" c_Alias=\"过滤条件\" c_Compox=\"filterCtrl\"></parameter>"
            + "<parametertable name=\"structureFields\" c_Alias=\"结构字段映射\">"
            + "<head><parameter name=\"columnName\" c_Alias=\"输出列名\"></parameter>"
            + "<parameter name=\"dataPath\" c_Alias=\"结构字段路径\"></parameter>"
            + "<parameter name=\"columnType\" c_Alias=\"输出列数据类型\" c_Compox=\"sightx-datatype\"></parameter>"
            + "<parameter name=\"formatFunc\" c_Alias=\"数据转换函数\" c_Option=\"true\"></parameter>"
            + "</head>" + "</parametertable>"
            + "</parametergroup></parametergroup></parameters>",
    compoxes = { @Compox(id = "filterModeCtrl",
        parentId = "sightx-switch",
        visibleDescriptors = {},
        dataDescriptor = @DataDesc(defaultValue = "filter",
            data = "[{\"label\": \"过滤\", \"value\": \"filter\"}, {\"label\": \"索引\", \"value\": \"index\"}]")),
        @Compox(id = "startPosCtrl",
            parentId = "sightx-uinteger",
            visibleDescriptors = {
                @VisibleDesc(visibleType = VisibleType.VISIBLE,
                    condition = "filterMode == \"index\"")
            }), @Compox(id = "endPosCtrl",
        parentId = "sightx-integer",
        visibleDescriptors = { @VisibleDesc(visibleType = VisibleType.VISIBLE,
            condition = "filterMode == \"index\"")
        }), @Compox(id = "filterCtrl",
        parentId = "sightx-input",
        visibleDescriptors = { @VisibleDesc(visibleType = VisibleType.VISIBLE,
            condition = "filterMode == \"filter\"")
        })
    })
public class JsonFlatterDescriptor extends AbstractFlatterDescriptor
    implements AutoStructMappingDescriptor {
  ......
}
```

---

## 六、说明

1. **必填项**：`name`、`type`、`inputPorts`、`outputPorts` 必须显式指定，其余属性均有默认值。
2. **configx 规范**：`parameters` 与 `DataDesc.data` 字段均遵循 configx 配置描述规范，用于声明参数项的类型、默认值、约束等。
3. **端口方向**：`inputPorts` 与 `outputPorts` 不可省略；若算子无输入或输出，应显式声明为空数组 `{}`。
4. **复合组件**：`compoxes` 仅在复杂算子（含子组件、可视化交互）时使用，普通原子算子可省略。
