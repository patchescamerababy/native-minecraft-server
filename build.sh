#!/usr/bin/env bash

set -o errexit
set -o nounset

SERVER_JAR_DL="https://piston-data.mojang.com/v1/objects/e6ec2f64e6080b9b5d9b471b291c33cc7f509733/server.jar"
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BUILD_DIR="${SCRIPT_DIR}/build"
JAR_PATH="${BUILD_DIR}/server.jar"
META_INF_PATH="${BUILD_DIR}/META-INF"
BINARY_NAME="native-minecraft-server"
NI_EXEC="${GRAALVM_HOME:-}/bin/native-image"
readonly SERVER_JAR_DL SCRIPT_DIR BUILD_DIR JAR_PATH META_INF_PATH BINARY_NAME NI_EXEC

# 检查 GraalVM 环境变量
if [[ -z "${GRAALVM_HOME:-}" ]]; then
    echo "\$GRAALVM_HOME is not set. Please provide a GraalVM installation. Exiting..."
    exit 1
fi

if ! command -v "${NI_EXEC}" &> /dev/null; then
    echo "Installing GraalVM Native Image..."
    "${GRAALVM_HOME}/bin/gu" install --no-progress native-image
fi

# 在 BUILD_DIR 中写入 eula.txt
mkdir "${JAR_PATH}/eula.txt"
echo "Writing eula.txt with 'eula=true' into ${JAR_PATH}"
echo "eula=true" > "${JAR_PATH}/eula.txt"

# 建立 build 目录
if [[ ! -d "${BUILD_DIR}" ]]; then
    mkdir "${BUILD_DIR}"
fi
pushd "${BUILD_DIR}" > /dev/null

# 下载 server.jar
if [[ ! -f "${JAR_PATH}" ]]; then
    echo "Downloading Minecraft's server.jar..."
    curl --show-error --fail --location -o "${JAR_PATH}" "${SERVER_JAR_DL}"
fi

# 解压 META-INF 目录中的资源
if [[ ! -d "${META_INF_PATH}" ]]; then
    echo "Extracting resources from Minecraft's server.jar..."
    unzip -qq "${JAR_PATH}" "META-INF/*" -d "."
fi

# 获取 classpath 配置
if [[ ! -f "${META_INF_PATH}/classpath-joined" ]]; then
    echo "Unable to determine classpath. Exiting..."
    exit 1
fi
CLASSPATH_JOINED=$(cat "${META_INF_PATH}/classpath-joined")
readonly CLASSPATH_JOINED

# 获取 main class 配置（后续 native-image 构建依赖，但配置生成阶段不再使用）
if [[ ! -f "${META_INF_PATH}/main-class" ]]; then
    echo "Unable to determine main class. Exiting..."
    exit 1
fi
MAIN_CLASS=$(cat "${META_INF_PATH}/main-class")
readonly MAIN_CLASS

# 使用 java -jar 运行 server.jar（而不是指定 main-class）以生成反射配置数据
echo "Running server.jar with native-image agent to generate configuration..."
java -agentlib:native-image-agent=config-output-dir=./configuration -jar "${JAR_PATH}" || echo "Native-image agent run completed (expected to exit prematurely)"

echo ""
echo "Starting native-image build..."
echo "${NI_EXEC}" --no-fallback \
    -H:ConfigurationFileDirectories="${SCRIPT_DIR}/configuration/" \
    --enable-url-protocols=https \
    --initialize-at-run-time=io.netty \
    -H:+AllowVMInspection \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    -H:Name="${BINARY_NAME}" \
    -cp "${CLASSPATH_JOINED//;/:}" \
    "${MAIN_CLASS}"

# 进入 META-INF 目录进行构建
pushd "${META_INF_PATH}" > /dev/null
"${NI_EXEC}" --no-fallback \
    -H:ConfigurationFileDirectories="${SCRIPT_DIR}/configuration/" \
    --enable-url-protocols=https \
    --initialize-at-run-time=io.netty \
    -H:+AllowVMInspection \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    -H:Name="${BINARY_NAME}" \
    -cp "${CLASSPATH_JOINED//;/:}" \
    "${MAIN_CLASS}"
mv "${BINARY_NAME}" "${SCRIPT_DIR}/${BINARY_NAME}"
popd > /dev/null # 退出 META-INF 目录
popd > /dev/null # 退出 BUILD_DIR

# 如果 upx 可用，则压缩生成的二进制文件
if command -v upx &> /dev/null; then
    echo "Compressing the native Minecraft server with upx..."
    upx "${SCRIPT_DIR}/${BINARY_NAME}"
fi

echo ""
echo "Done! The native Minecraft server is located at:"
echo "${SCRIPT_DIR}/${BINARY_NAME}"
