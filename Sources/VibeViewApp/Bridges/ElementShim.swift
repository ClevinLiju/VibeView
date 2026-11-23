import MolBuild

// Element lookup used by app code (switch to MolCore's table once available).
public enum BuildElementsShim {
    public static func symbol(_ z: Int) -> String { BuildElements.symbol(z) }
    public static func atomicNumber(_ s: String) -> Int? { BuildElements.atomicNumber(s) }
    public static func covalentRadius(_ z: Int) -> Double { BuildElements.covalentRadius(z) }
}
