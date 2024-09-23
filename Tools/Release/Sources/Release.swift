import ArgumentParser
import CommandLineTools
import Foundation

@main
struct Release: AsyncParsableCommand {
    @Option(help: "The version of the package that is being released.")
    var version: String

    @Option(help: "The branch of the source repository to build from.")
    var branch: String
    
    @Flag(help: "Prevents the run from pushing anything to GitHub.")
    var localOnly = false
    
    var sourceRepo = Repository(owner: "Ruchit-Xaana", name: "matrix-rust-sdk")
    var packageRepo = Repository(owner: "Ruchit-Xaana", name: "matrix-rust-components-swift")
    
    var packageDirectory: URL {
        return URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/package")
    }
    
    lazy var buildDirectory: URL = {
    let buildDirPath = "\(FileManager.default.currentDirectoryPath)/source"
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: buildDirPath) {
        fatalError("The directory 'source' does not exist at path: \(buildDirPath)")
    }
    return URL(fileURLWithPath: buildDirPath)
}()
    
    mutating func run() async throws {

        guard let apiToken = ProcessInfo.processInfo.environment["API_TOKEN_GITHUB"] else {
            fatalError("API Token not found. Please set the API_TOKEN_GITHUB environment variable.")
        }
        
        // Use the apiToken safely here
        print("API Token retrieved successfully.")
        // Checkout the specified branch and commit
        try checkoutBranchAndCommit()

        let package = Package(repository: packageRepo, directory: packageDirectory, apiToken: apiToken, urlSession: localOnly ? .releaseMock : .shared)
        Zsh.defaultDirectory = package.directory
        
        Log.info("Build directory: \(buildDirectory.path())")
        
        let product = try build()
        let (zipFileURL, checksum) = try package.zipBinary(with: product)
        
        try await updatePackage(package, with: product, checksum: checksum)
        try commitAndPush(package, with: product)
        try await package.makeRelease(with: product, uploading: zipFileURL)
    }

    mutating func checkoutBranchAndCommit() throws {
            let git = Git(directory: buildDirectory)

            // Checkout the specified branch
            try git.checkout(branch: branch)

            Log.info("Checked out branch \(branch)")
    }
    
    mutating func build() throws -> BuildProduct {
        let git = Git(directory: buildDirectory)
        // Use the checked out commit hash and branch name
        let commitHash = try git.commitHash

        Log.info("Building from commit \(commitHash) on branch \(branch)")
        
        // unset fixes an issue where swift compilation prevents building for targets other than macOS
        let cargoCommand = "cargo xtask swift build-framework --release --target aarch64-apple-ios --target aarch64-apple-ios-sim --target x86_64-apple-ios"
        try Zsh.run(command: "unset SDKROOT && \(cargoCommand)", directory: buildDirectory)
        
        return BuildProduct(sourceRepo: sourceRepo,
                            version: version,
                            commitHash: commitHash,
                            branch: branch,
                            directory: buildDirectory.appending(component: "bindings/apple/generated/"),
                            frameworkName: "MatrixSDKFFI.xcframework")
    }
    
    func updatePackage(_ package: Package, with product: BuildProduct, checksum: String) async throws {
        Log.info("Copying sources")
        let source = product.directory.appending(component: "swift", directoryHint: .isDirectory)
        let destination = package.directory.appending(component: "Sources/MatrixRustSDK", directoryHint: .isDirectory)
        try Zsh.run(command: "rsync -a --delete '\(source.path())' '\(destination.path())'")
        
        try await package.updateManifest(with: product, checksum: checksum)
    }
    
    func commitAndPush(_ package: Package, with product: BuildProduct) throws {
        Log.info("Pushing changes")
        
        let git = Git(directory: package.directory)
        try git.add(files: "Package.swift", "Sources")
        try git.commit(message: "Bump to version \(version) (\(product.sourceRepo.name)/\(product.branch) \(product.commitHash))")
        
        guard !localOnly else {
            Log.info("Skipping push for --local-only")
            return
        }
        
        try git.push()
    }
}
