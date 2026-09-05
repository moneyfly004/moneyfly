# MoneyFly Android 混淆规则
# mihomo 内核库（gomobile bind 生成：Java 壳 + JNI native + go/Seq 运行时）
-keep class top.moneyfly.mihomelib.** { *; }
-keep class go.** { *; }
# gomobile 依赖 java.lang.reflect / JNI 注册，保留元数据
-keepattributes *Annotation*,InnerClasses,EnclosingMethod,Signature
-dontwarn go.**
