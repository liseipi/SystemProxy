#!/bin/bash

# 这个脚本用于生成不同尺寸的图标
# 使用 ImageMagick v7 的 magick 命令进行图像调整大小
# 要求：安装 ImageMagick v7 (brew install imagemagick 或 apt install imagemagick)
# 注意：ImageMagick v7 已弃用 convert 命令，请使用 magick

# 检查是否安装了 ImageMagick (magick 命令)
if ! command -v magick &> /dev/null; then
    echo "错误：请先安装 ImageMagick v7（magick 命令）。"
    exit 1
fi

# 默认输入文件，如果没有提供参数则使用第一个参数
INPUT_FILE="${1:-icon.png}"
if [ ! -f "$INPUT_FILE" ]; then
    echo "错误：输入文件 '$INPUT_FILE' 不存在。"
    exit 1
fi

# 定义常见图标尺寸列表（可以根据需要修改）
SIZES=(16 32 48 64 128 256 512 1024)

# 输出目录，默认为当前目录下的 'icons' 文件夹
OUTPUT_DIR="icons"
mkdir -p "$OUTPUT_DIR"

# 循环生成每个尺寸的图标
for size in "${SIZES[@]}"; do
    OUTPUT_FILE="$OUTPUT_DIR/$(basename "$INPUT_FILE" .png)_${size}x${size}.png"
    magick "$INPUT_FILE" -resize "${size}x${size}" "$OUTPUT_FILE"
    if [ $? -eq 0 ]; then
        echo "生成成功: $OUTPUT_FILE"
    else
        echo "生成失败: $OUTPUT_FILE"
    fi
done

echo "所有图标生成完成！输出目录: $OUTPUT_DIR"