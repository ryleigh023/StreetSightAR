# The google_mlkit_text_recognition plugin references the Chinese,
# Devanagari, Japanese and Korean recognisers unconditionally, but only the
# Latin model is declared as a dependency. R8 treats the others as missing
# classes and fails the release build. We never select those scripts at
# runtime, so telling R8 not to warn is correct rather than a workaround.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# TensorFlow Lite loads its interpreter and delegates reflectively.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
