# اسم الملف الناتج (المكتبة)
TARGET = Mods.dylib

# المترجم (Compiler)
CXX = clang++

# مسارات المكتبات (يجب أن تتطابق مع مكان وجود ملفاتك)
CFLAGS = -dynamiclib -fPIC -std=c++17 -arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path)
FRAMEWORKS = -framework Foundation -framework UIKit

# الملفات المصدرية
SOURCES = Mods.mm

# عملية البناء
all:
	@echo "🛠 Building $(TARGET)..."
	$(CXX) $(CFLAGS) $(SOURCES) -o $(TARGET) $(FRAMEWORKS)
	@echo "✅ Build Complete: $(TARGET)"

# تنظيف الملفات المؤقتة
clean:
	rm -f $(TARGET)

.PHONY: all clean
