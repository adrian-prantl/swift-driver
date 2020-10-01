//===------- ModuleDependencyGraph.swift ----------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Foundation
import TSCBasic

/// The core information for the ModuleDependencyGraph
/// Isolate in a sub-structure in order to faciliate invariant maintainance
struct NodesAndUses {
  
  /// Maps swiftDeps files and DependencyKeys to Nodes
  fileprivate typealias NodeMap = TwoDMap<String?, DependencyKey, ModuleDepGraphNode>
  fileprivate var nodeMap = NodeMap()
  
  /// Since dependency keys use baseNames, they are coarser than individual
  /// decls. So two decls might map to the same key. Given a use, which is
  /// denoted by a node, the code needs to find the files to recompile. So, the
  /// key indexes into the nodeMap, and that yields a submap of nodes keyed by
  /// file. The set of keys in the submap are the files that must be recompiled
  /// for the use.
  /// (In a given file, only one node exists with a given key, but in the future
  /// that would need to change if/when we can recompile a smaller unit than a
  /// source file.)
  
  /// Tracks def-use relationships by DependencyKey.
  private(set)var usesByDef = Multidictionary<DependencyKey, ModuleDepGraphNode>()
}
// MARK: - finding
extension NodesAndUses {
  func findFileInterfaceNode(forSwiftDeps swiftDeps: String) -> ModuleDepGraphNode?  {
    let fileKey = DependencyKey(interfaceForSourceFile: swiftDeps)
    return findNode((swiftDeps, fileKey))
  }
  func findNode(_ mapKey: (String?, DependencyKey)) -> ModuleDepGraphNode? {
    nodeMap[mapKey]
  }
  
  func findNodes(for swiftDeps: String?) -> [DependencyKey: ModuleDepGraphNode]? {
    nodeMap[swiftDeps]
  }
  func findNodes(for key: DependencyKey) -> [String?: ModuleDepGraphNode]? {
    nodeMap[key]
  }

  /// Since uses must be somewhere, pass inthe swiftDeps to the function here
  func forEachUse(_ fn: (DependencyKey, ModuleDepGraphNode, String) -> Void) {
    usesByDef.forEach {
      def, use in
      fn(def, use, useMustHaveSwiftDeps(use))
    }
  }
  func forEachUse(of def: DependencyKey, _ fn: (ModuleDepGraphNode, String) -> Void) {
    usesByDef[def].map {
      $0.values.forEach { use in
        fn(use, useMustHaveSwiftDeps(use))
      }
    }
  }

  func mappings(of n: ModuleDepGraphNode) -> [(String?, DependencyKey)]
  {
    nodeMap.compactMap {
      k, _ in
      k.0 == n.swiftDeps && k.1 == n.dependencyKey
        ? k
        : nil
    }
  }

  func defsUsing(_ n: ModuleDepGraphNode) -> [DependencyKey] {
    usesByDef.keysContainingValue(n)
  }
}

fileprivate extension ModuleDepGraphNode {
  var mapKey: (String?, DependencyKey) {
    return (swiftDeps, dependencyKey)
  }
}

// MARK: - inserting

extension NodesAndUses {

  /// Add \c node to the structure, return the old node if any at those coordinates.
  /// \c isUsed helps for assertion checking.
  /// TODO: Incremental clean up doxygens
  @discardableResult
  mutating func insert(_ n: ModuleDepGraphNode, isUsed: Bool?)
  -> ModuleDepGraphNode?
  {
    nodeMap.updateValue(n, forKey: n.mapKey)
  }

  // TODO: Incremental consistent open { for fns

   /// record def-use, return if is new use
  mutating func record(def: DependencyKey, use: ModuleDepGraphNode)
  -> Bool {
    verifyUseIsOK(use)
    return usesByDef.addValue(use, forKey: def)
  }
}

// MARK: - removing
extension NodesAndUses {
  mutating func remove(_ nodeToErase: ModuleDepGraphNode) {
    // uses first preserves invariant that every used node is in nodeMap
    removeUsings(of: nodeToErase)
    removeMapping(of: nodeToErase)
  }

  private mutating func removeUsings(of nodeToNotUse: ModuleDepGraphNode) {
    usesByDef.removeValue(nodeToNotUse)
    assert(defsUsing(nodeToNotUse).isEmpty)
  }

  private mutating func removeMapping(of nodeToNotMap: ModuleDepGraphNode) {
    let old = nodeMap.removeValue(forKey: nodeToNotMap.mapKey)
    assert(old == nodeToNotMap, "Should have been there")
    assert(mappings(of: nodeToNotMap).isEmpty)
  }
}

// MARK: - moving
extension NodesAndUses {
 /// When integrating a SourceFileDepGraph, there might be a node representing
  /// a Decl that had previously been read as an expat, that is a node
  /// representing a Decl in no known file (to that point). (Recall the the
  /// Frontend processes name lookups as dependencies, but does not record in
  /// which file the name was found.) In such a case, it is necessary to move
  /// the node to the proper collection.
   mutating func move(_ nodeToMove: ModuleDepGraphNode, toDifferentFile newFile: String) {
    removeMapping(of: nodeToMove)
    nodeToMove.swiftDeps = newFile
    insert(nodeToMove, isUsed: nil)
  }
}

// MARK: - asserting & verifying
extension NodesAndUses {
  func verify() -> Bool {
    verifyNodeMap()
    verifyUsesByDef()
    return true
  }

  private func verifyNodeMap() {
    var nodes = [Set<ModuleDepGraphNode>(), Set<ModuleDepGraphNode>()]
    nodeMap.verify {
      _, v, submapIndex in
      if let prev = nodes[submapIndex].update(with: v) {
        fatalError("\(v) is also in nodeMap at \(prev), submap: \(submapIndex)")
      }
      v.verify()
    }
  }

  private func verifyUsesByDef() {
    usesByDef.forEach {
      def, use in
      // def may have disappeared from graph, nothing to do
      verifyUseIsOK(use)
    }
  }

  private func useMustHaveSwiftDeps(_ n: ModuleDepGraphNode)  -> String {
    assert(verifyUseIsOK(n))
    return n.swiftDeps!
  }

  @discardableResult
  private func verifyUseIsOK(_ n: ModuleDepGraphNode) -> Bool {
    verifyExpatsAreNotUses(n, isUsed: true)
    verifyNodeIsMapped(n)
    return true
  }

  private func verifyNodeIsMapped(_ n: ModuleDepGraphNode) {
    if findNode(n.mapKey) == nil {
      fatalError("\(n) should be mapped")
    }
  }

  /// isUsed is an optimization
  @discardableResult
  private func verifyExpatsAreNotUses(_ use: ModuleDepGraphNode, isUsed: Bool?) -> Bool {
    guard use.isExpat else {return true}
    let isReallyUsed = isUsed ?? !defsUsing(use).isEmpty
    if (isReallyUsed) {
      fatalError("An expat is not defined anywhere and thus cannot be used")
    }
    return false
  }
}
// MARK: - mapping back-and-forth to jobs
@_spi(Testing) public struct JobTracker {
  /// Keyed by swiftdeps filename, so we can get back to Jobs.
  private var jobsBySwiftDeps: [String: Job] = [:]


  func getJob(_ swiftDeps: String) -> Job {
    guard let job = jobsBySwiftDeps[swiftDeps] else {fatalError("All jobs should be tracked.")}
    // TODO: Incremental centralize job invars
    assert(job.swiftDepsPaths.contains(swiftDeps),
           "jobsBySwiftDeps should be inverse of getSwiftDeps.")
    return job
  }

  @_spi(Testing) public mutating func registerJob(_ job: Job) {
    // No need to create any nodes; that will happen when the swiftdeps file is
    // read. Just record the correspondence.
    job.swiftDepsPaths.forEach { jobsBySwiftDeps[$0] = job }
  }

  @_spi(Testing) public var allJobs: [Job] {
    Array(jobsBySwiftDeps.values)
  }

}

// MARK: - ModuleDependencyGraph

@_spi(Testing) public final class ModuleDependencyGraph {

  internal var nodesAndUses = NodesAndUses()

  // Supports requests from the driver to getExternalDependencies.
  @_spi(Testing) public internal(set) var externalDependencies = Set<String>()



  let verifyDependencyGraphAfterEveryImport: Bool
  let emitDependencyDotFileAfterEveryImport: Bool

  @_spi(Testing) public let diagnosticEngine: DiagnosticsEngine

  @_spi(Testing) public var jobTracker = JobTracker()


  public init(
    verifyDependencyGraphAfterEveryImport: Bool,
    emitDependencyDotFileAfterEveryImport: Bool,
    diagnosticEngine: DiagnosticsEngine)
  {
    self.verifyDependencyGraphAfterEveryImport = verifyDependencyGraphAfterEveryImport
    self.emitDependencyDotFileAfterEveryImport = emitDependencyDotFileAfterEveryImport
    self.diagnosticEngine = diagnosticEngine
  }
}

// MARK: - initial build only
extension ModuleDependencyGraph {
  static func buildInitialGraph(jobs: [Job],
                                verifyDependencyGraphAfterEveryImport: Bool,
                                emitDependencyDotFileAfterEveryImport: Bool,
                                diagnosticEngine: DiagnosticsEngine) -> Self {
    let r = Self(verifyDependencyGraphAfterEveryImport: verifyDependencyGraphAfterEveryImport,
                 emitDependencyDotFileAfterEveryImport: emitDependencyDotFileAfterEveryImport,
                 diagnosticEngine: diagnosticEngine)
    for job in jobs {
      _ = DepGraphIntegrator.integrate(job: job, into: r,
                                       diagnosticEngine: diagnosticEngine)
    }
    return r
  }
}

// MARK: - finding jobs
extension ModuleDependencyGraph {
  @_spi(Testing) public func findJobsToRecompileWhenWholeJobChanges(_ job: Job) -> [Job] {
    let allNodesInJob = findAllNodes(in: job)
    return findJobsToRecompileWhenNodesChange(allNodesInJob);
  }

  private func findAllNodes(in job: Job) -> [ModuleDepGraphNode] {
    job.swiftDepsPaths.flatMap(nodesIn(swiftDeps:))
  }
  
  @_spi(Testing) public func findJobsToRecompileWhenNodesChange(
    _ nodes: [ModuleDepGraphNode])
  -> [Job]
  {
    let affectedNodes = ModuleDepGraphTracer.findPreviouslyUntracedUsesOf(defs: nodes, in: self)
      .tracedUses
    return jobsContaining(affectedNodes)
  }



  // Add every (swiftdeps) use of the external dependency to foundJobs.
  // Can return duplicates, but it doesn't break anything, and they will be
  // canonicalized later.
  @_spi(Testing) public func findExternallyDependentUntracedJobs(_ externalDependency: String) -> [Job] {
    var foundJobs = [Job]()

    forEachUntracedJobDirectlyDependentOnExternalSwiftDeps(externalSwiftDeps: externalDependency) {
      job in
      foundJobs.append(job)
      // findJobsToRecompileWhenWholeJobChanges is reflexive
      // Don't return job twice.
      for marked in findJobsToRecompileWhenWholeJobChanges(job) where marked != job {
        foundJobs.append(marked)
      }
    }
    return foundJobs;
  }

  private func forEachUntracedJobDirectlyDependentOnExternalSwiftDeps(
    externalSwiftDeps: String,
    _ fn: (Job) -> Void
  ) {
    // TODO move nameForDep into key
    // These nodes will depend on the *interface* of the external Decl.
    let key = DependencyKey(interfaceForExternalDepend: externalSwiftDeps)
    nodesAndUses.forEachUse(of: key) {
      use, useSwiftDeps in
      if !use.hasBeenTraced {
        fn(jobTracker.getJob(useSwiftDeps))
      }
    }
  }


  private func jobsContaining<Nodes: Sequence>(_ nodes: Nodes) -> [Job]
  where Nodes.Element == ModuleDepGraphNode {
    computeSwiftDepsFromNodes(nodes).map(jobTracker.getJob)
  }




}


extension Job {
  @_spi(Testing) public var swiftDepsPaths: [String] {
    outputs.compactMap {$0.type != .swiftDeps ? nil : $0.file.name }
  }
}

// MARK: - finding nodes; swiftDeps
extension ModuleDependencyGraph {
  private func computeSwiftDepsFromNodes<Nodes: Sequence>(_ nodes: Nodes) -> [String]
  where Nodes.Element == ModuleDepGraphNode {
    var swiftDepsOfNodes = Set<String>()
    for n in nodes {
      if let swiftDeps = n.swiftDeps {
        swiftDepsOfNodes.insert(swiftDeps)
      }
    }
    return Array(swiftDepsOfNodes)
  }
}

// MARK: - purely for testing
extension ModuleDependencyGraph {
  /// Testing only
  @_spi(Testing) public func haveAnyNodesBeenTraversedIn(_ job: Job) -> Bool {
    for swiftDeps in job.swiftDepsPaths {
      // optimization
      if let fileNode = nodesAndUses.findFileInterfaceNode(forSwiftDeps: swiftDeps),
         fileNode.hasBeenTraced
      {
        return true
      }
      if  nodesIn(swiftDeps: swiftDeps).contains(where: {$0.hasBeenTraced}) {
        return true
      }
    }
    return false
  }
  
  private func nodesIn(swiftDeps: String) -> [ModuleDepGraphNode]
  {
    nodesAndUses.findNodes(for: swiftDeps)
      .map {Array($0.values)}
    ?? []
  }
}



// MARK: - key helpers

fileprivate extension DependencyKey {
  init(interfaceForSourceFile swiftDeps: String) {
    self.init(aspect: .interface,
              designator: .sourceFileProvide(name: swiftDeps))
  }

  init(interfaceForExternalDepend externalSwiftDeps: String ) {
    self.init(aspect: .interface,
              designator: .externalDepend(name: externalSwiftDeps))
  }

}

// MARK: - verificaiton
extension ModuleDependencyGraph {
  @discardableResult
  func verifyGraph() -> Bool {
    nodesAndUses.verify()
  }
}


// MARK: - debugging
extension ModuleDependencyGraph {
  func emitDotFile(_ g: SourceFileDependencyGraph, _ swiftDeps: String) {
    // TODO: Incremental emitDotFIle
    fatalError("unimplmemented")
  }
}
