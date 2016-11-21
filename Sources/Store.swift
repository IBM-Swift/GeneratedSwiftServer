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

public protocol Store {
    // TODO(tunniclm): Maybe change to using an associated type
    // This may require restructuring Models to no longer be tied to Stores.
    //associatedtype ID: ModelID
    static func ID(_ id: Any) throws -> ModelID
    func findAll(type: Model.Type, callback: @escaping EntitiesCallback)
    func findOne(type: Model.Type, id: ModelID, callback: @escaping EntityCallback) throws
    func create(type: Model.Type, id: ModelID?, entity: [String:Any], callback: @escaping EntityCallback) throws
    func createOrUpdate(type: Model.Type, id: ModelID?, entity: [String:Any], callback: @escaping EntityCallback) throws
    func update(type: Model.Type, id: ModelID, entity: [String:Any], callback: @escaping EntityCallback) throws
    func replace(type: Model.Type, id: ModelID, entity: [String:Any], callback: @escaping EntityCallback) throws
    func delete(type: Model.Type, id: ModelID, callback: @escaping EntityCallback) throws
    func deleteAll(type: Model.Type, callback: @escaping ErrorCallback) throws
}

public typealias EntitiesCallback = ([[String:Any]], StoreError?) -> Void
public typealias EntityCallback   = ([String:Any]?,  StoreError?) -> Void
public typealias ErrorCallback    = (StoreError?) -> Void

public extension Store {
    func createOrUpdate(type: Model.Type, id: ModelID?, entity: [String:Any], callback: @escaping EntityCallback) throws {
        if let id = id {
            try update(type: type, id: id, entity: entity) { result, error in
                if case .notFound? = error {
                    // NOTE(tunniclm): create() should only throw a StoreError.idInvalid
                    // if the provided id does not match the ModelID implementation for
                    // the Store implementation. However, this should already have
                    // been checked in the outer call to update(), therefore we should
                    // be able to assume this call wont throw.
                    try! self.create(type: type, id: id, entity: entity, callback: callback)
                } else {
                    callback(result, error)
                }
            }
        } else {
            try create(type: type, id: nil, entity: entity, callback: callback)
        }
    }
}
