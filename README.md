# HuggingFists 算子开发规范（OpSpec）

面向**自行开发算子**的用户：说明如何对接 HuggingFists 扩展机制，开发并打包算子后导入平台自用。

开源示例：[Datayoo/datayoo-ops](https://github.com/Datayoo/datayoo-ops)——可对照现成算子，也可交给大模型按规范帮写骨架。

相关资源：

- 文档：[飞书文档](https://datayoo-doc.feishu.cn/wiki/JwKiwuBJWi9XfqkU7fqckoZonZf)
- 视频：[Bilibili 空间](https://space.bilibili.com/3493257067629101)

## 声明

用户自行开发、导入、使用的算子由用户自行负责，**不视为官方算子**，与 Datayoo / HuggingFists 产品默认支持范围无关。本规范只说明对接方式，不对自研算子做验收、背书或运维承诺。

## 阅读顺序

| 编号 | 文档 | 内容 |
|------|------|------|
| 00 | [原则与范围](docs/00-原则与范围.md) | 读者、管什么不管什么 |
| 01 | [概念与架构](docs/01-概念与架构.md) | 定义态 / 实现态、引擎、边界 |
| — | [官方算子分组](docs/官方算子分组.md) | 界面路径 → tag |
| — | [OpDefiner 注解说明](docs/OpDefiner注解说明.md) | 注解字段 |
| 02 | [定义态](docs/02-定义态.md) | Descriptor：注解、继承、打包 |
| 03 | [实现态](docs/03-实现态.md) | Oyez：对齐、生命周期、打包 |
| 04 | [导入与自验](docs/04-导入与自验.md) | 导入平台并自己确认能用 |

路径：**概念 → 定义态 → 实现态 → 导入**。

## 仓库目录

```text
docs/            # 规范正文与说明
scaffold/        # 算子工程脚手架（待补充）
idea-plugin/     # IDEA 开发插件（待补充）
platform-deps/   # 平台私有依赖 lib + install-lib 脚本
```

## License

[MIT](LICENSE)
