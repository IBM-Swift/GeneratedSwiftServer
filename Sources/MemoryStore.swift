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

import Foundation

public class MemoryStore: Store {
    struct MemoryStoreID: ModelID {
        let value: Int

        init(_ id: Any) throws {
            switch id {
            case let int as Int: value = int
            case let number as NSNumber: value = Int(number)
            case let string as String where Int(string) != nil: value = Int(string)!
            default: throw StoreError.idInvalid(id)
            }
        }

        var description: String {
            return String(describing: value)
        }

        func convert(to: PropertyDefinition.PropertyType) -> Any? {
            switch to {
            case .string: return String(describing: value)
            case .number: return value
            case .object: return value
            default: return nil
            }
        }
    }
    public static func ID(_ id: Any) throws -> ModelID {
        return try MemoryStoreID(id)
    }

    private static func mergeDictionary(_ dest: inout [String:Any], merge: [String:Any]) {
        for (key, value) in merge {
            dest[key] = value
        }
    }

    private func changeID(from memoryStoreID: MemoryStoreID, to newID: Any?, type: Model.Type, callback: @escaping EntityCallback) throws -> MemoryStoreID {
        if let newID = try newID.map({ try MemoryStoreID($0) }) {
            if newID.value != memoryStoreID.value {
                // Changing the id of this model
                if let (_, _) = findOne_(type: type, id: newID) {
                    // NOTE(tunniclm): The new id must not clash with existing model
                    callback(nil, .idConflict(newID))
                    return memoryStoreID
                }
                // NOTE(tunniclm): Update the counter to prevent future clashes of generated ids
                if newID.value >= nextId {
                    nextId = newID.value + 1
                }
                return newID
            }
        }
        return memoryStoreID
    }

    private static func sanitize(entity: [String:Any]) -> [String:Any] {
        var sanitizedEntity = entity
        sanitizedEntity.removeValue(forKey: "_type")
        return sanitizedEntity
    }

    var entities: [[String:Any]] = []
    var nextId: Int = 1

    public init() {}

    public func findAll(type: Model.Type, callback: @escaping EntitiesCallback) {
        let matchingEntities = entities.filter { $0["_type"] as! Model.Type == type }
                                       .map(MemoryStore.sanitize)
        callback(matchingEntities, nil)
    }

    private func findOne_(type: Model.Type, id: MemoryStoreID) -> ([String:Any], Int)? {
        let maybeIndex = entities.index { $0["_type"] as! Model.Type == type && ($0["id"] as! MemoryStoreID).value == id.value }
        return maybeIndex.map { (MemoryStore.sanitize(entity: entities[$0]), $0) }
    }
    public func findOne(type: Model.Type, id: ModelID, callback: @escaping EntityCallback) throws {
        guard let memoryStoreID = id as? MemoryStoreID else {
            // TODO(tunniclm): This failure path may go away if Store
            // is made generic over ModelID
            throw StoreError.idInvalid(id)
        }
        if let entity = findOne_(type: type, id: memoryStoreID)?.0 {
            callback(entity, nil)
        } else {
            callback(nil, .notFound(id))
        }
    }

    public func create(type: Model.Type, id: ModelID?, entity: [String:Any], callback: @escaping EntityCallback) throws {
        var modifiedEntity = entity
        // NOTE(tunniclm): Ignore any id in the JSON, we should respect
        // the _id_ parameter instead
        modifiedEntity.removeValue(forKey: "id")
        // TODO(tunniclm): We are ignoring the case where the caller could
        // pass an id that is some different ModelID than CloudantStoreID.
        // In the future, using a generic constraint could remove this possibility.
        // For now, perhaps we should handle this rather than pretending its
        // the same as not providing an id at all.
        if let id = id as? MemoryStoreID {
            if let (_, _) = findOne_(type: type, id: id) {
                // NOTE(tunniclm): Not allowed to create with an id that already exists
                callback(nil, .idConflict(id))
                return
            }
            // NOTE(tunniclm): Create with a specified id
            var newItem = entity // NOTE(tunniclm): Assumes entity is a value type
            if id.value >= nextId {
                nextId = id.value + 1
            }
            newItem["_type"] = type
            newItem["id"] = id
            entities.append(newItem)
            callback(MemoryStore.sanitize(entity: newItem), nil)
        } else {
            // NOTE(tunniclm): Generate an id
            var newItem = entity // NOTE(tunniclm): Assumes entity is a value type
            newItem["id"] = try MemoryStoreID(nextId)
            newItem["_type"] = type
            nextId += 1
            entities.append(newItem)
            callback(MemoryStore.sanitize(entity: newItem), nil)
        }
    }

    public func update(type: Model.Type, id: ModelID, entity: [String:Any], callback: @escaping EntityCallback) throws {
        guard let memoryStoreID = id as? MemoryStoreID else {
            throw StoreError.idInvalid(id)
        }

        guard let (existing, index) = findOne_(type: type, id: memoryStoreID) else {
            // NOTE(tunniclm): Only allowed to update existing models
            callback(nil, .notFound(memoryStoreID))
            return
        }

        var updatedItem = existing
        MemoryStore.mergeDictionary(&updatedItem, merge: entity)
        updatedItem["_type"] = type
        updatedItem["id"] = try changeID(from: memoryStoreID, to: entity["id"], type: type, callback: callback)

        entities[index] = updatedItem
        callback(MemoryStore.sanitize(entity: updatedItem), nil)
    }

    public func replace(type: Model.Type, id: ModelID, entity: [String : Any], callback: @escaping EntityCallback) throws {
        guard let memoryStoreID = id as? MemoryStoreID else {
            throw StoreError.idInvalid(id)
        }
        guard let (_, index) = findOne_(type: type, id: memoryStoreID) else {
            // NOTE(tunniclm): Only allowed to replace existing models
            callback(nil, .notFound(memoryStoreID))
            return
        }

        var resultEntity = entity
        resultEntity["_type"] = type
        resultEntity["id"] = try changeID(from: memoryStoreID, to: entity["id"], type: type, callback: callback)

        entities[index] = resultEntity
        callback(MemoryStore.sanitize(entity: resultEntity), nil)
    }

    public func delete(type: Model.Type, id: ModelID, callback: @escaping EntityCallback) throws {
        // TODO(tunniclm): Generics might help with this type constraint (make parameter "id: CloudantStoreID").
        guard let memoryStoreID = id as? MemoryStoreID else {
            // TODO(tunniclm): This failure path may go away if Store
            // is made generic over ModelID
            throw StoreError.idInvalid(id)
        }
        if let (entity, index) = findOne_(type: type, id: memoryStoreID) {
            entities.remove(at: index)
            callback(entity, nil)
        }
        callback(nil, .notFound(memoryStoreID))
    }

    public func deleteAll(type: Model.Type, callback: @escaping ErrorCallback) {
        entities.removeAll()
        callback(nil)
    }
}

