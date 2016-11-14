/*
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import SwiftyJSON
import Foundation

open class Model {
    public static var store: Store!
    static var definitions: [String:(Model.Type,ModelDefinition)] = [:]
    var properties: [String:Any]

    static func injectDefaults(_ properties: [String:Any]) -> [String:Any] {
        // NOTE(tunniclm): validate that required properties have been provided
        guard let (_, modelDef) = Model.definitions[String(describing: self)] else {
            // NOTE(tunniclm): Model not found in the definitions dictionary
            // This should not happen, there must be a logical error in the code
            assert(false)
            return properties
        }
        var updatedProperties = properties
        for (propertyName, propertyDef) in modelDef.properties {
            if updatedProperties[propertyName] == nil {
                if let defaultValue = propertyDef.defaultValue {
                    updatedProperties[propertyName] = defaultValue
                }
            }
        }
        return updatedProperties
    }

    static func ensureValid(_ properties: [String:Any]) throws {
        // NOTE(tunniclm): validate that required properties have been provided
        guard let (_, modelDef) = Model.definitions[String(describing: self)] else {
            // NOTE(tunniclm): Model not found in the definitions dictionary
            // This should not happen, there must be a logical error in the code
            assert(false)
            return
        }
        for (propertyName, propertyDef) in modelDef.properties {
            if propertyDef.isRequired && properties[propertyName] == nil {
                throw ModelError.requiredPropertyMissing(name: propertyName)
            }
        }
    }

    public required init(_ properties: [String:Any]) throws {
        // NOTE(tunniclm): require that properties contain a valid id
        let modelType = type(of: self)
        var modelID: ModelID?
        if let id = properties["id"] {
            modelID = id as? ModelID
            if modelID == nil {
                let storeType = type(of: modelType.store as Store)
                modelID = try storeType.ID(id)
            }
        }
        try modelType.ensureValid(properties)
        self.properties = modelType.injectDefaults(properties)
        guard let (_, defn) = modelType.definitions[String(describing: modelType)] else {
            throw InternalError("No definition found for model \(modelType)")
        }
        // TODO(tunniclm): OK to allow models that don't store the id?
        // TODO(tunniclm): Allow id properties named something else
        if let id = modelID,
           let property = defn.properties["id"] {
            guard let convertedID = id.convert(to: property.type) else {
                // NOTE(tunniclm): Could not convert store id to requested type
                // TODO(tunniclm): Handle this better
                throw InternalError("ID conversion failed")
            }
            guard property.sameTypeAs(object: convertedID) else {
                // NOTE(tunniclm): internal error, store did not actually convert
                // to the type we asked for
                throw InternalError("ID conversion result has an incompatible type")
            }
            self.properties["id"] = convertedID
        }
    }

    static func loadModels(fromDir url: URL) throws -> [(String, String)] {
        var failures: [(String, String)] = []

        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        
        for file in files.filter({ $0.lastPathComponent.hasSuffix(".json") }) {
            if let data = try? Data(contentsOf: file) { // TODO(tunniclm): Take a look at what this throws
                do {
                    let modelDefinition = try ModelDefinition(json: JSON(data: data))
                    let modelClassName = "Generated." + modelDefinition.className
                    if let modelClass = NSClassFromString(modelClassName) as? Model.Type {
                        definitions[modelDefinition.className] = (modelClass, modelDefinition)
                    } else {
                        failures.append((file.lastPathComponent, "Unable to load class \(modelClassName)"))
                    }
                } catch ModelDefinition.Error.invalidSchema(let message) {
                    // Failed to define model from file due to invalid schema (see message); skip file.
                    failures.append((file.lastPathComponent, message));
                }
            }
        }
        return failures
    }

    // NOTE(tunniclm): The provided modelDict should have come from the store.
    // This means that it must:
    // * have valid properties (at the time it was saved)
    private static func from(modelDict: [String:Any]) throws -> Model {
        // NOTE(tunniclm): initializer will convert "id" property
        // from ModelID to appropriate value to match model definition
        return try self.init(modelDict)
    }

    private static func definition(for propertyName: String) throws -> PropertyDefinition? {
        guard let (_, modelDefinition) = definitions[String(describing: self)] else {
            throw InternalError("No definition found for model \(self)")
        }
        return modelDefinition.properties[propertyName]
    }

    // findOne
    //   Read a model of the matching type and id from the configured Store.
    //
    // throws:
    //   ModelError.requiredPropertyMissing("id") - if the id is missing or empty
    //   ModelError.propertyTypeMismatch(...) - if the id is not compatible with the Model
    //   StoreError.idInvalid(id) - if the id is not compatible with the Store
    //   InternalError - if there is a logic error
    // passes to callback:
    //   resultModel - the matching model, with type matching the type on which findOne was called.
    //                 Will be nil if no matching model is found, or if an error occurred.
    //   error - the error that occurred, or nil if no error occurred.
    //           Error types:
    //           * StoreError.notFound(id) - if no entity with the provided id was found in the Store
    //           * StoreError.storeUnavailable(reason) - if the Store is not in a ready state to service queries
    //           * StoreError.internalError - if there is a logic error
    static func findOne(_ maybeID: String?, callback: @escaping (Model?, StoreError?) -> Void) throws {
        guard let stringID = maybeID, stringID != "" else {
            throw ModelError.requiredPropertyMissing(name: "id")
        }
        let storeType = type(of: store as Store)
        if let defn = try self.definition(for: "id") {
            guard let modelID = defn.convertValue(fromString: stringID) else {
                throw ModelError.propertyTypeMismatch(name: defn.name, type: String(describing: defn.type),
                                                      value: stringID, valueType: "String")
            }
            let storeModelID = try storeType.ID(modelID)
            try findOne_(storeModelID, callback: callback)
        } else {
            let storeModelID = try storeType.ID(stringID)
            try findOne_(storeModelID, callback: callback)
        }
    }

    // Assumes:
    // * id is compatible with the Store we are using (caller should ensure this)
    private static func findOne_(_ id: ModelID, callback: @escaping (Model?, StoreError?) -> Void) throws {
        do {
            try store.findOne(type: self, id: id) { entity, error in
                do {
                    callback(try entity.map { try self.from(modelDict: $0) }, error)
                } catch let error as InternalError {
                    callback(nil, StoreError.internalError(error.message))
                } catch {
                    assert(false)
                    callback(nil, StoreError.internalError(String(describing: error)))
                }
            }
        } catch {
            let storeType = type(of: store as Store)
            throw InternalError("Reading entity (type: \(self), id: \(id)) from store \(storeType)", causedBy: error)
        }
    }

    // findAll
    //   Reads all models of the matching type from the configured Store.
    //
    // passes to callback:
    // * resultModels - an array of models found in the Store. Each model type matches the type
    //                  on which findAll() was called.
    //                  Will be an empty array if no matching models are found, or if an error occurred.
    // * error - the error that occurred, or nil if no error occurred.
    //           Error types:
    //           * StoreError.storeUnavailable(reason) - if the Store is not in a ready state to service queries
    //           * StoreError.internalError - if there is a logic error
    static func findAll(callback: @escaping ([Model], StoreError?) -> Void) {
        store.findAll(type: self) { entities, error in
            do {
                callback(try entities.map { try self.from(modelDict: $0) }, error)
            } catch let error as InternalError {
                callback([], StoreError.internalError(error.message))
            } catch {
                callback([], StoreError.internalError(String(describing: error)))
            }
        }
    }

    private static func forEachValidPropertyInJSON(_ json: JSON, callback: @escaping (String,Any) -> Void) throws {
        // NOTE(tunniclm): Look up the model definition for this Model subclass
        // TODO This is using the name of the subclass as a key in a dictionary
        // of registered model definitions. We probably shouldn't do this, since
        // it ties model names directly to the named of Swift classes, which is
        // quite restrictive.
        guard let (_, model) = definitions[String(describing: self)] else {
            // NOTE(tunniclm): Model not found in the definitions dictionary
            // This should not happen, there must be a logical error in the code
            assert(false)
            return
        }

        // NOTE(tunniclm): Construct an entity description from the provided JSON
        // object, dropping any extraneous or mismatching properties
        for (jsonPropertyName, jsonValue) in json.dictionaryValue {
            guard let property = model.properties[jsonPropertyName] else {
                // NOTE(tunniclm): Property provided in the JSON is not found in the
                // model definition, so ignore it.
                throw ModelError.extraneousProperty(name: jsonPropertyName)
            }
            print("Found property definition for \(jsonPropertyName): \(property)") // DEBUG

            if let value = property.convertValue(fromJSON: jsonValue) {
                print("Setting \(property.name) property to \(value)") // DEBUG
                // TODO Validate property -- custom validations etc
                callback(property.name, value)
            } else {
                // NOTE(tunniclm): Property provided in the JSON does not have a type
                // that matches the property in the model definition, so ignore it.
                throw ModelError.propertyTypeMismatch(name: property.name, type: String(describing: property.type),
                                                      value: jsonValue.description, valueType: String(describing: jsonValue.type))
            }
        }
    }

    // create
    //   Create a model as defined by the provided JSON and write it to the configured Store.
    //   Use the "id" property of the JSON, if provided, as the id to store the model against
    //   in the Store.
    //
    // throws:
    //   ModelError.requiredPropertyMissing(name) - if any property marked required in the model definition is missing from the JSON
    //   ModelError.extraneousProperty(name) - if the JSON supplies any property not present in the model definition
    //   ModelError.propertyTypeMismatch(...) - if any JSON property's type fails to match the model definition
    //   StoreError.idInvalid(id) - if an id is provided and is not compatible with the Store
    //   InternalError - if there is a logic error
    // passes to callback:
    //   resultModel - the created model, with type matching the type on which create was called.
    //                 Will be nil if, and only if, there is an error.
    //   error - the error that occurred, or nil if no error occurred.
    //           If an error occurs, the model will not be created (exception: if it is an InternalError,
    //           the model may still be created).
    //           Error types:
    //           * StoreError.idConflict(id) - if an id is provided and the id is already in use by another entity
    //           * StoreError.storeUnavailable(reason) - if the Store is not in a ready state to service queries
    //           * StoreError.internalError - if there is a logic error
    static func create(json: JSON, callback: @escaping (Model?, StoreError?) -> Void) throws {
        var entity: [String:Any] = [:]
        try self.forEachValidPropertyInJSON(json) { name, value in
            entity[name] = value
        }
        try ensureValid(entity)
        let id = try entity["id"].map { try type(of: store as Store).ID($0) }
        try self.create_(id, entity, callback: callback)
    }

    // Assumes:
    // * id is compatible with the Store we are using (caller should ensure this)
    // * type checking of properties has already been performed and found compatible
    private static func create_(_ id: ModelID?, _ entity: [String:Any], callback: @escaping (Model?, StoreError?) -> Void) throws {
        do {
            try store.create(type: self, id: id, entity: entity) { entity, error in
                do {
                    callback(try entity.map({ try self.from(modelDict: $0) }), error)
                } catch let error as InternalError {
                    callback(nil, .internalError(error.message))
                } catch {
                    callback(nil, .internalError(String(describing: error)))
                }
            }
        } catch {
            let storeType = type(of: store as Store)
            throw InternalError("Creating entity (type: \(self), value: \(entity)) in store \(storeType)", causedBy: error)
        }
    }

    // update
    //   Update a model of the matching type and id as defined by the provided JSON and write it to 
    //   the configured Store.
    //
    // throws:
    //   ModelError.requiredPropertyMissing("id") - if the id is missing or empty
    //   ModelError.extraneousProperty(name) - if the JSON supplies any property not present in the model definition
    //   ModelError.propertyTypeMismatch(...) - if any JSON property's type fails to match the model definition
    //   StoreError.idInvalid(id) - if an id is provided and is not compatible with the Store
    //   InternalError - if there is a logic error
    // passes to callback:
    //   resultModel - the updated model, with type matching the type on which create was called.
    //                 Will be nil if, and only if, there is an error.
    //   error - the error that occurred, or nil if no error occurred.
    //           If an error occurs, the model will not be created (exception: if it is an InternalError,
    //           the model may still be created).
    //           Error types:
    //           * StoreError.notFound(id) - if no entity with the provided id was found in the Store
    //           * StoreError.idConflict(id) - if an id is provided and the id is already in use by another entity
    //           * StoreError.storeUnavailable(reason) - if the Store is not in a ready state to service queries
    //           * StoreError.internalError - if there is a logic error
    static func update(_ id: String?, json: JSON, callback: @escaping (Model?, StoreError?) -> Void) throws {
        guard let id = id else {
            throw ModelError.requiredPropertyMissing(name: "id")
        }
        var entity: [String:Any] = [:]
        try self.forEachValidPropertyInJSON(json) { name, value in
            entity[name] = value
        }
        let modelID = try type(of: store as Store).ID(id)
        try self.update_(modelID, entity, callback: callback)
    }

    // TODO Check -- an update can only set or edit properties to non-nil values and
    // as such an update will not put an entity in a state where it is missing
    // required properties. This may well be bogus--you should probably be able to
    // set (non-required) properites to nil.
    // Assumes:
    // * id is compatible with the Store we are using (caller should ensure this)
    // * type checking of properties has already been performed and found compatible
    private static func update_(_ id: ModelID, _ entity: [String:Any], callback: @escaping (Model?, StoreError?) -> Void) throws {
        do {
            try store.update(type: self, id: id, entity: entity) { entity, error in
                do {
                    callback(try entity.map({ try self.from(modelDict: $0) }), error)
                } catch let error as InternalError {
                    callback(nil, StoreError.internalError(error.message))
                } catch {
                    callback(nil, StoreError.internalError(String(describing: error)))
                }
            }
        } catch {
            let storeType = type(of: store as Store)
            throw InternalError("Updating entity (type: \(self), id: \(id), updates: \(entity)) in store \(storeType)", causedBy: error)
        }
    }

    // delete
    //   Delete a model of the matching type and id from the configured Store.
    //
    // throws:
    //   StoreError.idInvalid(id) - if the provided id is not compatible with the Store
    //   InternalError - if there is a logic error
    // passes to callback:
    //   resultModel - the matching model, with type matching the type on which delete was called.
    //                 Will be nil if no matching model is found, or if an error occurred.
    // * error - the error that occurred, or nil if no error occurred. If an error occurred, the document will
    //           not be deleted.
    //           Error types:
    //           * StoreError.notFound(id) - if no entity with the provided id was found in the Store
    //           * StoreError.storeUnavailable(reason) - if the Store is not in a ready state to service queries
    //           * StoreError.internalError - if there is a logic error
    static func delete(_ id: String?, callback: @escaping (Model?, StoreError?) -> Void) throws {
        guard let id = id else {
            throw ModelError.requiredPropertyMissing(name: "id")
        }
        let modelID = try type(of: store as Store).ID(id)
        try delete_(modelID, callback: callback)
    }

    static func deleteAll(callback: @escaping (StoreError?) -> Void) throws {
        try store.deleteAll(type: self, callback: callback)
    }

    // Assumes:
    // * id is compatible with the Store we are using (caller should ensure this)
    private static func delete_(_ id: ModelID, callback: @escaping (Model?, StoreError?) -> Void) throws {
        do {
            try store.delete(type: self, id: id) { entity, error in
                do {
                    callback(try entity.map { try self.from(modelDict: $0) }, error)
                } catch let error as InternalError {
                    callback(nil, StoreError.internalError(error.message))
                } catch {
                    assert(false)
                    callback(nil, StoreError.internalError(String(describing: error)))
                }
            }
        } catch {
            let storeType = type(of: store as Store)
            throw InternalError("Deleting entity (type: \(self), id: \(id)) in store \(storeType)", causedBy: error)
        }
    }

    func update(json: JSON) throws -> Model {
        try type(of: self).forEachValidPropertyInJSON(json) { name, value in
            self.properties[name] = value
        }
        return self
    }

    // TODO should probably return this object rather than a new one
    // TODO deal with the scenario where calling code can findOne() a mode
    //      update its id, then save--in this case you could end up overwriting
    //      a pre-existing saved model with the new id (and the old saved model
    //      will not be updated).
    func save(callback: @escaping (Model?, StoreError?) -> Void) throws {
        let modelType = type(of: self)
        let storeType = type(of: modelType.store as Store)
        let id = try properties["id"].map { try storeType.ID($0) }
        try modelType.store.createOrUpdate(type: modelType, id: id, entity: properties) { entity, error in
            do {
                callback(try entity.map { try modelType.from(modelDict: $0) }, error)
            } catch let error as InternalError {
                callback(nil, StoreError.internalError(error.message))
            } catch {
                callback(nil, StoreError.internalError(String(describing: error)))
            }
        }
    }

    func delete(callback: @escaping (Model?, StoreError?) -> Void) throws {
        let modelType = type(of: self)
        let storeType = type(of: modelType.store as Store)
        guard let id = properties["id"] else {
            throw InternalError("Entity from store is missing an id")
        }
        let modelID = try storeType.ID(id)
        try modelType.delete_(modelID, callback: callback)
    }

    func json() -> JSON {
        var result = JSON([:])
        for (key, value) in properties {
            result[key] = JSON(value)
        }
        return result
    }
}
