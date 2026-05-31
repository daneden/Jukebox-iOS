//
//  AppGroupStore.swift
//  Jukebox
//
//  Shared storage location so the app, its App Intents, and the widget
//  extension all read/write the SAME History + Exclusion data. Each store's
//  named `ModelConfiguration` otherwise resolves to the *calling process's*
//  sandbox container — which is why an out-of-app intent and the widget
//  extension couldn't see the app's exclusions or record into its history.
//
//  TARGET MEMBERSHIP: app + WidgetsExtension (the control reads/writes the
//  shared stores too).
//
//  Requires the `group.me.daneden.Jukebox` App Group capability on both
//  targets. Falls back to the per-process default location when the
//  entitlement is absent, so the app still builds/runs before it's added.
//

import Foundation
import SwiftData

enum AppGroupStore {
	static let identifier = "group.me.daneden.Jukebox"

	/// Shared key-value store (last-run hints for "avoid repeating"), shared
	/// across the app and the extension. Nil when the entitlement is absent.
	static var defaults: UserDefaults? {
		UserDefaults(suiteName: identifier)
	}

	static var containerURL: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
	}

	/// SwiftData configuration for `name`, in the shared App Group container
	/// when available, else the legacy per-process named default.
	static func configuration(_ name: String, schema: Schema) -> ModelConfiguration {
		guard let dir = containerURL else {
			return legacyConfiguration(name, schema: schema)
		}
		return ModelConfiguration(
			schema: schema,
			url: dir.appendingPathComponent("\(name).store"),
			cloudKitDatabase: .none
		)
	}

	/// The pre-App-Group named configuration (default location), kept only so
	/// `migrate` can read existing rows out of it.
	static func legacyConfiguration(_ name: String, schema: Schema) -> ModelConfiguration {
		ModelConfiguration(name, schema: schema, cloudKitDatabase: .none)
	}

	/// One-time, per-process migration guard. Per-process (not the shared
	/// suite) on purpose: the app must still migrate its own legacy data even
	/// if the extension touched the shared store first.
	static func needsMigration(_ name: String) -> Bool {
		containerURL != nil && !UserDefaults.standard.bool(forKey: "appgroup.migrated.\(name)")
	}

	static func markMigrated(_ name: String) {
		UserDefaults.standard.set(true, forKey: "appgroup.migrated.\(name)")
	}

	// MARK: - Last-run hints

	/// Seed artist/decade of the most recent generated playlist, shared so
	/// the next run (from the app, Siri, or a control) can steer away from it
	/// — the parity-with-shuffle "feel very different each time" behaviour.
	static var lastSeedArtist: String? {
		get { defaults?.string(forKey: "lastSeedArtist") }
		set { defaults?.set(newValue, forKey: "lastSeedArtist") }
	}

	static var lastSeedDecade: Int? {
		get {
			guard let d = defaults, d.object(forKey: "lastSeedDecade") != nil else { return nil }
			return d.integer(forKey: "lastSeedDecade")
		}
		set {
			if let newValue { defaults?.set(newValue, forKey: "lastSeedDecade") }
			else { defaults?.removeObject(forKey: "lastSeedDecade") }
		}
	}
}
