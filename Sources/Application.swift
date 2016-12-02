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
import Kitura
import KituraNet
import SwiftyJSON
import LoggerAPI

public class Application {
    public struct ProjectRootNotFoundError: Swift.Error {}

    public let router: Router

    public static func findProjectRoot(from initialSearchPath: String = #file) -> URL? {
        let fileManager = FileManager()

        let fileURL = URL(fileURLWithPath: initialSearchPath)
        let directoryURL = fileURL.deletingLastPathComponent()

        var searchDirectory = directoryURL
        while searchDirectory.path != "/" {
            let projectFilePath = searchDirectory.appendingPathComponent(".swiftservergenerator-project").path
            if fileManager.fileExists(atPath: projectFilePath) {
                return searchDirectory
            }
            searchDirectory.deleteLastPathComponent()
        }
        return nil
    }

    public convenience init() throws {
        guard let projectRoot = Application.findProjectRoot() else {
            throw ProjectRootNotFoundError()
        }
        self.init(projectRoot: projectRoot)
    }

    public init(projectRoot: URL) {
        router = Router()

        router.all("/api/*", middleware: BodyParser())

        // Load model definitions
        do {
            let failures = try Model.loadModels(fromDir: projectRoot.appendingPathComponent("models"))
            for (file, message) in failures {
                Log.error("Skipped loading model \(file) due to error: \(message)")
            }
        } catch {
            Log.error("Failed to load models from ./models: \(error)")
        }

        if Model.definitions.count == 0 {
            Log.error("No models were loaded, exiting")
            exit(1)
        }

        // Generate the routes for each model
        for (_, (modelClass, modelDefn)) in Model.definitions {
            let onePath = "/api/\(modelDefn.plural)/:id"
            let allPath = "/api/\(modelDefn.plural)"

            Log.info("Defining routes for \(modelDefn.name)")

            Log.info("Defining DELETE \(allPath)")
            router.delete(allPath) { req, res, next in
                Log.debug("DELETE \(allPath)")
                do {
                    try modelClass.deleteAll() { error in
                        if let _ = error {
                            res.status(.internalServerError)
                        } else {
                            let result = JSON([])
                            res.send(json: result)
                        }
                        next()
                    }
                } catch {
                    res.status(.internalServerError)
                    return next()
                }
            }

            Log.info("Defining GET \(allPath)")
            router.get(allPath) { req, res, next in
                Log.debug("GET \(allPath)")
                modelClass.findAll() { models, error in
                    if let _ = error {
                        res.status(.internalServerError)
                    } else {
                        let result = JSON(models.map { $0.json() })
                        res.send(json: result)
                    }
                    next()
                }
            }

            Log.info("Defining GET \(onePath)")
            router.get(onePath) { req, res, next in
                do {
                    Log.debug("GET \(onePath)")
                    try modelClass.findOne(req.parameters["id"]) { model, error in
                        switch error {
                        case nil:
                            guard let model = model else {
                                res.status(.internalServerError)
                                return next()
                            }
                            res.send(json: model.json())
                        case .notFound?:
                            res.status(.notFound)
                        default:
                            res.status(.internalServerError)
                        }
                        next()
                    }
                } catch let error as ModelError {
                    if case ModelError.propertyTypeMismatch(let name, _, _, _) = error,
                       name == "id" {
                        res.status(.badRequest)
                    } else {
                        // NOTE(tunniclm): findOne() should only throw
                        // idInvalid errors
                        res.status(.internalServerError)
                    }
                    res.send(json: JSON([ "error": error.defaultMessage() ]))
                    return next()
                } catch {
                    res.status(.internalServerError)
                    return next()
                }
            }

            Log.info("Defining POST \(allPath)")
            router.post(allPath) { req, res, next in
                Log.debug("POST \(allPath)")
                guard let contentType = req.headers["Content-Type"],
                      contentType.hasPrefix("application/json") else {
                    res.status(.unsupportedMediaType)
                    res.send(json: JSON([ "error": "Request Content-Type must be application/json" ]))
                    return next()
                }
                guard case let .json(json)? = req.body else {
                    res.status(.badRequest)
                    res.send(json: JSON([ "error": "Request body could not be parsed as JSON" ]))
                    return next()
                }

                do {
                    try modelClass.create(json: json) { model, error in
                        if let error = error {
                            switch error {
                            case .idConflict(let id):
                                res.status(.conflict)
                                res.send(json: JSON([ "error": "Cannot create model with existing id \(id)" ]))
                            default:
                                res.status(.internalServerError)
                            }
                        } else if let model = model {
                            res.send(json: model.json())
                        } else {
                            // NOTE(tunniclm): This should not happen, findOne() should
                            // either provide a valid result or an error
                            res.status(.internalServerError)
                        }
                        next()
                    }
                } catch let error as ModelError {
                    res.status(.unprocessableEntity)
                    res.send(json: JSON([ "error": error.defaultMessage() ]))
                    next()
                } catch {
                    Log.error("Unexpected error type \(error)")
                    res.status(.internalServerError)
                    next()
                }
            }

            Log.info("Defining PUT \(onePath)")
            router.put(onePath) { req, res, next in
                Log.debug("PUT \(onePath)")
                guard let contentType = req.headers["Content-Type"],
                    contentType.hasPrefix("application/json") else {
                        res.status(.unsupportedMediaType)
                        res.send(json: JSON(["error": "Request Content-type must be application/json"]))
                        return next()
                }
                guard let body = req.body else {
                    res.status(.badRequest)
                    res.send(json: JSON([ "error": "Missing request body" ]))
                    return next()
                }
                guard case let .json(json) = body else {
                    res.status(.badRequest)
                    res.send(json: JSON([ "error": "Request body could not be parsed as JSON" ]))
                    return next()
                }

                do {
                    try modelClass.replace(req.parameters["id"], json: json) { model, error in
                        switch error {
                        case nil:
                            guard let model = model else {
                                // NOTE(tunniclm): This should not happen, replace() should
                                // either provide a valid result or an error
                                res.status(.internalServerError)
                                return next()
                            }
                            res.send(json: model.json())
                            return next()
                        case .notFound?:
                            res.status(.notFound)
                            return next()
                        case .idConflict(let id)?:
                            res.status(.conflict)
                            res.send(json: JSON([ "error": "Cannot update id to a value that already exists (\(id))" ]))
                            return next()
                        default:
                            res.status(.internalServerError)
                            return next()
                        }
                    }
                } catch let error as ModelError {
                    switch error {
                    case .propertyTypeMismatch(name: "id", _, _, _),
                         .requiredPropertyMissing(name: "id"):
                        res.status(.badRequest)
                    default:
                        res.status(.unprocessableEntity)
                    }
                    res.send(json: JSON([ "error": error.defaultMessage() ]))
                    return next()
                } catch {
                    res.status(.internalServerError)
                    return next()
                }

            }

            Log.info("Defining PATCH \(onePath)")
            router.patch(onePath) { req, res, next in
                Log.debug("PATCH \(onePath)")
                guard let contentType = req.headers["Content-Type"],
                      contentType.hasPrefix("application/json") else {
                    res.status(.unsupportedMediaType)
                    res.send(json: JSON([ "error": "Request Content-Type must be application/json" ]))
                    return next()
                }
                guard let body = req.body else {
                    res.status(.badRequest)
                    res.send(json: JSON([ "error": "Missing request body" ]))
                    return next()
                }
                guard case let .json(json) = body else {
                    res.status(.badRequest)
                    res.send(json: JSON([ "error": "Request body could not be parsed as JSON" ]))
                    return next()
                }

                do {
                    try modelClass.update(req.parameters["id"], json: json) { model, error in
                        switch error {
                        case nil:
                            guard let model = model else {
                                // NOTE(tunniclm): This should not happen, update() should
                                // either provide a valid result or an error
                                res.status(.internalServerError)
                                return next()
                            }
                            res.send(json: model.json())
                            return next()
                        case .notFound?:
                            res.status(.notFound)
                            return next()
                        case .idConflict(let id)?:
                            res.status(.conflict)
                            res.send(json: JSON([ "error": "Cannot update id to a value that already exists (\(id))" ]))
                            return next()
                        default:
                            res.status(.internalServerError)
                            return next()
                        }
                    }
                } catch let error as ModelError {
                    switch error {
                    case .propertyTypeMismatch(name: "id", _, _, _),
                         .requiredPropertyMissing(name: "id"):
                        res.status(.badRequest)
                    default:
                        res.status(.unprocessableEntity)
                    }
                    res.send(json: JSON([ "error": error.defaultMessage() ]))
                    return next()
                } catch {
                    res.status(.internalServerError)
                    return next()
                }
            }

            Log.info("Defining DELETE \(onePath)")
            router.delete(onePath) { req, res, next in
                do {
                    Log.debug("DELETE \(onePath)")
                    try modelClass.delete(req.parameters["id"]) { model, error in
                        switch error {
                        case nil:
                            guard let _ = model else {
                                res.status(.internalServerError)
                                return next()
                            }
                            res.send(json: JSON([ "count": 1 ]))
                        case .notFound?:
                            res.send(json: JSON([ "count": 0 ]))
                        default:
                            res.status(.internalServerError)
                        }
                        next()
                    }
                } catch let error as ModelError {
                    switch error {
                    case .propertyTypeMismatch(name: "id", _, _, _),
                         .requiredPropertyMissing(name: "id"):
                        res.status(.badRequest)
                    default:
                        // NOTE(tunniclm): delete() should only throw
                        // idInvalid errors
                        res.status(.internalServerError)
                    }
                    res.send(json: JSON([ "error": error.defaultMessage() ]))
                    return next()
                } catch {
                    res.status(.internalServerError)
                    return next()
                }
            }
        }
    }
}
