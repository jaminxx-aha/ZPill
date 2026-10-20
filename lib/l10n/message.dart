/// 可本地化消息的统一形状(纯 Dart,无 Flutter 依赖 —— 核心层可引用)。
///
/// 无 BuildContext 的层(连接层/控制器)吐消息时只存 **抽象键 + 占位
/// 参数**;消费端(有 context)统一 `t(key, args)` 渲染。键在 zh/en
/// 两词表未命中时经 t() 直通 —— [key] 也可以是运行期动态串($e 插值
/// 串、原生上报值),此时 [args] 为 null,与未抽取时代口径一致。
typedef L10nMessage = ({String key, Map<String, Object>? args});
