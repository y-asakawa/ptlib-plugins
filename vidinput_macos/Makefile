# プラグイン名
PLUGIN_NAME = vidinput_macos

# 出力する共有ライブラリ（PTLib 命名規則に従って _pwplugin サフィックスを使用）
PLUGIN_LIB = $(PLUGIN_NAME)_pwplugin.dylib

# ソースファイル（Objective-C++ 用に拡張子 .mm）
SRC = vidinput_macos.mm

# ヘッダーファイル
HDR = vidinput_macos.h

# PTLib のインストール先。ローカル環境に合わせて make 実行時に上書きしてください。
# 例: make PTLIB_DIR=/opt/ptlib
PTLIB_DIR ?= /usr/local
PTLIB_LIB_DIR ?= $(PTLIB_DIR)/lib
PTLIB_PLUGIN_DIR ?= $(PTLIB_LIB_DIR)

# PTLib, AVFoundation などの必要なヘッダーとライブラリのパス
PTLIB_INC ?= -I$(PTLIB_DIR)/include
PTLIB_LIB ?= -L$(PTLIB_LIB_DIR)

# macOS のフレームワーク（Foundation を追加）
MACOS_FRAMEWORKS = -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation -framework CoreGraphics -framework AppKit

# コンパイルオプション（clang++ を使用、ARC 有効）
CXX = clang++
CXXFLAGS = -std=c++17 -fPIC -Wall -Wextra $(PTLIB_INC)
# LDFLAGS に libobjc を追加
LDFLAGS = -dynamiclib $(PTLIB_LIB) -lpt $(MACOS_FRAMEWORKS) -lobjc

# ビルド対象
all: $(PLUGIN_LIB)

# 共有ライブラリのビルド
$(PLUGIN_LIB): $(SRC) $(HDR)
	$(CXX) $(CXXFLAGS) $(SRC) -o $(PLUGIN_LIB) $(LDFLAGS)

# インストール（PTLib のプラグインディレクトリへコピー）
install: $(PLUGIN_LIB)
	mkdir -p $(PTLIB_PLUGIN_DIR)
	cp $(PLUGIN_LIB) $(PTLIB_PLUGIN_DIR)/

# クリーンアップ
clean:
	rm -f $(PLUGIN_LIB)

# 再ビルド
rebuild: clean all install
