// Tests/VibeCountTests/MockFirestoreBackend.swift
import Foundation
@testable import VibeCount

actor MockFirestoreBackend: FirestoreBackend {
    private(set) var calls: [String] = []
    private var documents: [String: FirestoreDocument] = [:]
    private var listResults: [String: [FirestoreDocument]] = [:]
    private var errors: [String: FirestoreClientError] = [:]
    private var signInResult: Result<String, FirestoreClientError> = .success("uid-1")

    func setSignIn(_ result: Result<String, FirestoreClientError>) { signInResult = result }
    func setDocument(path: String, fields: [String: FirestoreValue]) {
        documents[path] = FirestoreDocument(name: "projects/t/databases/(default)/documents/\(path)", fields: fields)
    }
    func removeDocument(path: String) { documents[path] = nil }
    func setList(_ docs: [FirestoreDocument], forPath path: String) { listResults[path] = docs }
    func setError(_ error: FirestoreClientError, forPath path: String) { errors[path] = error }
    func document(path: String) -> FirestoreDocument? { documents[path] }

    private func checkError(_ path: String) throws {
        if let error = errors[path] { throw error }
    }

    func signIn() async throws -> String {
        calls.append("signIn")
        return try signInResult.get()
    }

    func getDocument(path: String) async throws -> FirestoreDocument? {
        calls.append("get \(path)")
        try checkError(path)
        return documents[path]
    }

    func patchDocument(path: String, fields: [String: FirestoreValue]) async throws {
        calls.append("patch \(path)")
        try checkError(path)
        documents[path] = FirestoreDocument(name: "projects/t/databases/(default)/documents/\(path)", fields: fields)
    }

    func createDocument(parent: String, documentID: String,
                        fields: [String: FirestoreValue]) async throws {
        let path = "\(parent)/\(documentID)"
        calls.append("create \(path)")
        try checkError(path)
        guard documents[path] == nil else { throw FirestoreClientError.alreadyExists }
        documents[path] = FirestoreDocument(name: "projects/t/databases/(default)/documents/\(path)", fields: fields)
    }

    func deleteDocument(path: String) async throws {
        calls.append("delete \(path)")
        try checkError(path)
        documents[path] = nil
    }

    func listDocuments(path: String) async throws -> [FirestoreDocument] {
        calls.append("list \(path)")
        try checkError(path)
        return listResults[path] ?? []
    }

    func batchGet(paths: [String]) async throws -> [String: FirestoreDocument?] {
        calls.append("batchGet \(paths.sorted().joined(separator: ","))")
        for path in paths { try checkError(path) }
        var result: [String: FirestoreDocument?] = [:]
        for path in paths { result[path] = .some(documents[path]) }
        return result
    }
}
