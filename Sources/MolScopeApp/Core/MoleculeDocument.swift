import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MolCore
import MolIO

// SHARED APP CORE (owned by Lead 4). Reading/writing is delegated to IOBridge.

public extension UTType {
    static let gaussianInput = UTType(exportedAs: "org.molscope.gaussian-input", conformingTo: .plainText)
    static let gaussianOutput = UTType(exportedAs: "org.molscope.gaussian-output", conformingTo: .plainText)
    static let formattedCheckpoint = UTType(exportedAs: "org.molscope.fchk", conformingTo: .plainText)
    static let cubeFile = UTType(exportedAs: "org.molscope.cube", conformingTo: .plainText)
    static let xyzFile = UTType(exportedAs: "org.molscope.xyz", conformingTo: .plainText)
    static let pdbFile = UTType(exportedAs: "org.molscope.pdb", conformingTo: .plainText)
    static let mdlMolFile = UTType(exportedAs: "org.molscope.mol", conformingTo: .plainText)
    static let sdfFile = UTType(exportedAs: "org.molscope.sdf", conformingTo: .plainText)
    static let cmlFile = UTType(exportedAs: "org.molscope.cml", conformingTo: .xml)
    static let orcaInput = UTType(exportedAs: "org.molscope.orca-input", conformingTo: .plainText)
    static let moldenFile = UTType(exportedAs: "org.molscope.molden", conformingTo: .plainText)
    static let orcaHessian = UTType(exportedAs: "org.molscope.orca-hessian", conformingTo: .plainText)
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
        MolFormat(name: "Calculation Output", type: .gaussianOutput, extensions: ["log", "out"], canWrite: false),
        MolFormat(name: "Formatted Checkpoint", type: .formattedCheckpoint, extensions: ["fchk", "fch"], canWrite: false),
        MolFormat(name: "Cube", type: .cubeFile, extensions: ["cube", "cub"], canWrite: false),
        MolFormat(name: "XYZ", type: .xyzFile, extensions: ["xyz"], canWrite: true),
        MolFormat(name: "PDB", type: .pdbFile, extensions: ["pdb", "ent"], canWrite: true),
        MolFormat(name: "MDL Molfile", type: .mdlMolFile, extensions: ["mol"], canWrite: true),
        MolFormat(name: "SD File", type: .sdfFile, extensions: ["sdf", "sd"], canWrite: true),
        MolFormat(name: "CML", type: .cmlFile, extensions: ["cml"], canWrite: true),
        MolFormat(name: "ORCA Input", type: .orcaInput, extensions: ["inp"], canWrite: false),
        MolFormat(name: "Molden", type: .moldenFile, extensions: ["molden"], canWrite: false),
        MolFormat(name: "ORCA Hessian", type: .orcaHessian, extensions: ["hess"], canWrite: false),
    ]
    public static func forType(_ t: UTType) -> MolFormat? { all.first { t.conforms(to: $0.type) } }
    public static func forExtension(_ e: String) -> MolFormat? { all.first { $0.extensions.contains(e.lowercased()) } }
}

public struct MoleculeDocument: FileDocument {
    public var molecule: Molecule
    public var result: CalculationResult?
    /// Original text of the file (for e.g. showing the source of a log).
    public var sourceFormat: MolFormat?
    public var wavefunction: Wavefunction?

    public init(molecule: Molecule = Molecule(title: "Untitled"), result: CalculationResult? = nil) {
        self.molecule = molecule
        self.result = result
    }

    /// Our own UTIs plus the generic types the system often assigns to these extensions (.log → com.apple.log,
    /// .out/.inp → plain text or data); the actual format is then decided from the extension and content.
    public static var readableContentTypes: [UTType] {
        MolFormat.all.map(\.type) + [.plainText, .text, UTType("com.apple.log"), .xml, .data].compactMap { $0 }
    }
    public static var writableContentTypes: [UTType] { MolFormat.all.filter(\.canWrite).map(\.type) }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let byExt = configuration.file.filename.flatMap { MolFormat.forExtension(($0 as NSString).pathExtension) }
        let fmt = MolFormat.all.first { $0.type == configuration.contentType } ?? byExt ?? MolFormat.forType(configuration.contentType)
        let ext = fmt?.ext ?? ((configuration.file.filename ?? "") as NSString).pathExtension
        let loaded = try IOBridge.read(data: data, ext: ext, fileName: configuration.file.filename)
        molecule = loaded.molecule
        result = loaded.result
        wavefunction = loaded.wavefunction
        sourceFormat = fmt
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Never write structure text over a calculation log or other read-only source file.
        guard let fmt = MolFormat.all.first(where: { $0.type == configuration.contentType }), fmt.canWrite else {
            throw CocoaError(.fileWriteUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                "This file type is read-only in MolScope. Use File ▸ Save As… or Duplicate to save the structure as .gjf, .xyz, .mol, .pdb or .cml."])
        }
        let data = try IOBridge.write(molecule, ext: fmt.ext)
        return FileWrapper(regularFileWithContents: data)
    }
}
