import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MolCore

// SHARED APP CORE (owned by Lead 4). Reading/writing is delegated to IOBridge.

public extension UTType {
    static let gaussianInput = UTType(exportedAs: "org.vibeview.gaussian-input", conformingTo: .plainText)
    static let gaussianOutput = UTType(exportedAs: "org.vibeview.gaussian-output", conformingTo: .plainText)
    static let formattedCheckpoint = UTType(exportedAs: "org.vibeview.fchk", conformingTo: .plainText)
    static let cubeFile = UTType(exportedAs: "org.vibeview.cube", conformingTo: .plainText)
    static let xyzFile = UTType(exportedAs: "org.vibeview.xyz", conformingTo: .plainText)
    static let pdbFile = UTType(exportedAs: "org.vibeview.pdb", conformingTo: .plainText)
    static let mdlMolFile = UTType(exportedAs: "org.vibeview.mol", conformingTo: .plainText)
    static let sdfFile = UTType(exportedAs: "org.vibeview.sdf", conformingTo: .plainText)
    static let cmlFile = UTType(exportedAs: "org.vibeview.cml", conformingTo: .xml)
}

/// One entry per supported format. `ext` is the canonical extension passed to IOBridge.
public struct MolFormat: Sendable, Hashable {
    public let name: String
    public let type: UTType
    public let extensions: [String]
    public let canWrite: Bool
    public var ext: String { extensions[0] }

    public static let all: [MolFormat] = [
        MolFormat(name: "Gaussian Input", type: .gaussianInput, extensions: ["gjf", "com"], canWrite: true),
        MolFormat(name: "Gaussian Output", type: .gaussianOutput, extensions: ["log", "out"], canWrite: false),
        MolFormat(name: "Formatted Checkpoint", type: .formattedCheckpoint, extensions: ["fchk", "fch"], canWrite: false),
        MolFormat(name: "Cube", type: .cubeFile, extensions: ["cube", "cub"], canWrite: false),
        MolFormat(name: "XYZ", type: .xyzFile, extensions: ["xyz"], canWrite: true),
        MolFormat(name: "PDB", type: .pdbFile, extensions: ["pdb", "ent"], canWrite: true),
        MolFormat(name: "MDL Molfile", type: .mdlMolFile, extensions: ["mol"], canWrite: true),
        MolFormat(name: "SD File", type: .sdfFile, extensions: ["sdf", "sd"], canWrite: true),
        MolFormat(name: "CML", type: .cmlFile, extensions: ["cml"], canWrite: true),
    ]
    public static func forType(_ t: UTType) -> MolFormat? { all.first { t.conforms(to: $0.type) } }
    public static func forExtension(_ e: String) -> MolFormat? { all.first { $0.extensions.contains(e.lowercased()) } }
}

public struct MoleculeDocument: FileDocument {
    public var molecule: Molecule
    public var result: CalculationResult?
    /// Original text of the file (for e.g. showing the source of a log).
    public var sourceFormat: MolFormat?

    public init(molecule: Molecule = Molecule(title: "Untitled"), result: CalculationResult? = nil) {
        self.molecule = molecule
        self.result = result
    }

    public static var readableContentTypes: [UTType] { MolFormat.all.map(\.type) }
    public static var writableContentTypes: [UTType] { MolFormat.all.filter(\.canWrite).map(\.type) }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let fmt = MolFormat.forType(configuration.contentType)
            ?? configuration.file.filename.flatMap { MolFormat.forExtension(($0 as NSString).pathExtension) }
        guard let fmt else { throw CocoaError(.fileReadUnsupportedScheme) }
        let loaded = try IOBridge.read(data: data, ext: fmt.ext)
        molecule = loaded.molecule
        result = loaded.result
        sourceFormat = fmt
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let fmt = MolFormat.forType(configuration.contentType) ?? MolFormat.all[0]
        let data = try IOBridge.write(molecule, ext: fmt.canWrite ? fmt.ext : "gjf")
        return FileWrapper(regularFileWithContents: data)
    }
}
