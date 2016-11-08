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
        updatedItem["id"] = id
        
        if let newId = try entity["id"].map({ try MemoryStoreID($0) }) {
            if newId.value != memoryStoreID.value {
                // NOTE(tunniclm): Changing the id of this model
                if let (_, _) = findOne_(type: type, id: newId) {
                    // NOTE(tunniclm): The new id must not clash with existing model
                    callback(nil, .idConflict(memoryStoreID))
                    return
                }
                // NOTE(tunniclm): Update the counter to prevent future clashes of generated ids
                if newId.value >= nextId {
                    nextId = newId.value + 1
                }
                updatedItem["id"] = newId
            }
        }
        
        entities[index] = updatedItem
        callback(MemoryStore.sanitize(entity: updatedItem), nil)
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

