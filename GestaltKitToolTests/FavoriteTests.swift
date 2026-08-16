//
//  FavoriteTests.swift
//  GestaltKitToolTests
//

import XCTest
@testable import GestaltKitTool

final class FavoriteTests: XCTestCase {
    func testFavoriteDefaultName() {
        let fav = Favorite(path: "/var/mobile/Containers/Data/UUID/Documents")
        XCTAssertEqual(fav.name, "Documents")
    }

    func testFavoriteCustomName() {
        let fav = Favorite(path: "/var/mobile/Containers/Data/UUID", name: "My App")
        XCTAssertEqual(fav.name, "My App")
    }

    func testFavoriteIdIsPath() {
        let path = "/var/mobile/test"
        let fav = Favorite(path: path)
        XCTAssertEqual(fav.id, path)
    }

    func testFavoriteCodable() throws {
        let fav = Favorite(path: "/test/path", name: "Test")
        let data = try JSONEncoder().encode(fav)
        let decoded = try JSONDecoder().decode(Favorite.self, from: data)
        XCTAssertEqual(fav, decoded)
    }

    func testFavoriteHashable() {
        let fav1 = Favorite(path: "/a", name: "A")
        let fav2 = Favorite(path: "/a", name: "B")
        let set: Set<Favorite> = [fav1, fav2]
        // Same path = same ID = same hash, so only one survives in Set.
        XCTAssertEqual(set.count, 1)
    }
}

final class AppContainerTests: XCTestCase {
    func testContainerEqualityById() {
        let c1 = AppContainer(id: "uuid-1", path: "/a", bundleIdentifier: "com.test", displayName: "Test", containerType: .data)
        let c2 = AppContainer(id: "uuid-1", path: "/b", bundleIdentifier: nil, displayName: "Other", containerType: .appGroup)
        // Same ID → equal.
        XCTAssertEqual(c1, c2)
    }

    func testContainerInequalityById() {
        let c1 = AppContainer(id: "uuid-1", path: "/a", bundleIdentifier: nil, displayName: "A", containerType: .data)
        let c2 = AppContainer(id: "uuid-2", path: "/a", bundleIdentifier: nil, displayName: "A", containerType: .data)
        XCTAssertNotEqual(c1, c2)
    }

    func testContainerHashById() {
        let c1 = AppContainer(id: "uuid-1", path: "/a", bundleIdentifier: nil, displayName: "A", containerType: .data)
        let c2 = AppContainer(id: "uuid-1", path: "/b", bundleIdentifier: nil, displayName: "B", containerType: .shared)
        let set: Set<AppContainer> = [c1, c2]
        XCTAssertEqual(set.count, 1)
    }

    func testContainerTypes() {
        XCTAssertEqual(AppContainer.ContainerType.data.rawValue, "Data")
        XCTAssertEqual(AppContainer.ContainerType.appGroup.rawValue, "AppGroup")
        XCTAssertEqual(AppContainer.ContainerType.shared.rawValue, "Shared")
    }
}
