// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WebViewAPM",
    platforms: [
        .iOS(.v13) // 指定支持的最低 iOS 版本 (WKWebView 和现代 Swift 特性需要较高版本)
    ],
    products: [
        // 定义其他 App 或 Package 可以依赖的库
        .library(
            name: "WebViewAPM",
            targets: ["WebViewAPM"]),
    ],
    dependencies: [
    ],
    targets: [
        // 定义构成库的主要 Target
        .target(
            name: "WebViewAPM",
            dependencies: [], // 内部 Target 依赖 (如果有)
            path: "WebViewAPM", // 相对于 Package.swift 的路径
            sources: ["Core"], // 指定源码子目录 (相对于 path)
            resources: [
                // 处理资源文件 (JS 脚本)
                .process("Resources/JavaScriptAgent.js")
            ]
        )
    ]
) 