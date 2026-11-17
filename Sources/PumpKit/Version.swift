//
//  Version.swift
//  PumpKit
//
//  迈世通（MedNovo）胰岛素泵 BLE 驱动 —— 纯 Swift 版
//  协议来源：AAPS 厂商改版 APK 反编译（plugins/pump/demose）
//

import Foundation

public enum PumpKitInfo {
    public static let version = "0.1.0"
    /// 泵的 BLE 设备名前缀（源 apk: ABytes.PATTERN = "^IP\\d[\\.-]"）
    public static let deviceNamePattern = #"^IP\d[\.-]"#
}
