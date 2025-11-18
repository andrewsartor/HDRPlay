//
//  Item.swift
//  HDRPlayDemo
//
//  Created by Andrew Sartor on 2025/11/18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
