module Cli exposing (run)

import Ansi.Color
import BackendTask
import BackendTask.File
import Cli.Option
import Cli.OptionsParser
import Cli.Program
import FatalError
import Json.Decode
import Json.Encode
import OpenApi
import OpenApi.Generate
import OpenApi.Info
import Pages.Script
import UrlPath
import Yaml.Decode


type alias CliOptions =
    { entryFilePath : String
    , outputDirectory : String
    , outputModuleName : Maybe String
    , generateTodos : Maybe String
    }


program : Cli.Program.Config CliOptions
program =
    Cli.Program.config
        |> Cli.Program.add
            (Cli.OptionsParser.build CliOptions
                |> Cli.OptionsParser.with
                    (Cli.Option.requiredPositionalArg "entryFilePath")
                |> Cli.OptionsParser.with
                    (Cli.Option.optionalKeywordArg "output-dir"
                        |> Cli.Option.withDefault "generated"
                    )
                |> Cli.OptionsParser.with
                    (Cli.Option.optionalKeywordArg "module-name")
                |> Cli.OptionsParser.with
                    (Cli.Option.optionalKeywordArg "generateTodos")
            )


run : Pages.Script.Script
run =
    Pages.Script.withCliOptions program
        (\{ entryFilePath, outputDirectory, outputModuleName, generateTodos } ->
            BackendTask.File.rawFile entryFilePath
                |> BackendTask.mapError
                    (\error ->
                        FatalError.fromString <|
                            Ansi.Color.fontColor Ansi.Color.brightRed <|
                                case error.recoverable of
                                    BackendTask.File.FileDoesntExist ->
                                        "Uh oh! There is no file at " ++ entryFilePath

                                    BackendTask.File.FileReadError _ ->
                                        "Uh oh! Can't read!"

                                    BackendTask.File.DecodingError _ ->
                                        "Uh oh! Decoding failure!"
                    )
                |> BackendTask.andThen decodeOpenApiSpecOrFail
                |> BackendTask.andThen
                    (generateFileFromOpenApiSpec
                        { outputDirectory = outputDirectory
                        , outputModuleName = outputModuleName
                        , generateTodos = generateTodos
                        }
                    )
        )


decodeOpenApiSpecOrFail : String -> BackendTask.BackendTask FatalError.FatalError OpenApi.OpenApi
decodeOpenApiSpecOrFail input =
    let
        -- TODO: Better handling of errors: https://github.com/wolfadex/elm-api-sdk-generator/issues/40
        decoded : Result Json.Decode.Error OpenApi.OpenApi
        decoded =
            case Yaml.Decode.fromString yamlToJsonDecoder input of
                Err _ ->
                    Json.Decode.decodeString OpenApi.decode input

                Ok jsonFromYaml ->
                    Json.Decode.decodeValue OpenApi.decode jsonFromYaml
    in
    decoded
        |> Result.mapError
            (Json.Decode.errorToString
                >> Ansi.Color.fontColor Ansi.Color.brightRed
                >> FatalError.fromString
            )
        |> BackendTask.fromResult


yamlToJsonDecoder : Yaml.Decode.Decoder Json.Encode.Value
yamlToJsonDecoder =
    Yaml.Decode.oneOf
        [ Yaml.Decode.map Json.Encode.float Yaml.Decode.float
        , Yaml.Decode.map Json.Encode.string Yaml.Decode.string
        , Yaml.Decode.map Json.Encode.bool Yaml.Decode.bool
        , Yaml.Decode.map (\_ -> Json.Encode.null) Yaml.Decode.null
        , Yaml.Decode.map
            (Json.Encode.list identity)
            (Yaml.Decode.list (Yaml.Decode.lazy (\_ -> yamlToJsonDecoder)))
        , Yaml.Decode.map
            (Json.Encode.dict identity identity)
            (Yaml.Decode.dict (Yaml.Decode.lazy (\_ -> yamlToJsonDecoder)))
        ]


generateFileFromOpenApiSpec :
    { outputDirectory : String
    , outputModuleName : Maybe String
    , generateTodos : Maybe String
    }
    -> OpenApi.OpenApi
    -> BackendTask.BackendTask FatalError.FatalError ()
generateFileFromOpenApiSpec config apiSpec =
    let
        moduleName : String
        moduleName =
            case config.outputModuleName of
                Just modName ->
                    modName

                Nothing ->
                    apiSpec
                        |> OpenApi.info
                        |> OpenApi.Info.title
                        |> OpenApi.Generate.sanitizeModuleName
                        |> Maybe.withDefault "Api"

        filePath : String
        filePath =
            config.outputDirectory
                ++ "/"
                ++ (moduleName
                        |> String.split "."
                        |> String.join "/"
                   )
                ++ ".elm"

        generateTodos : Bool
        generateTodos =
            List.member
                (String.toLower <| Maybe.withDefault "no" config.generateTodos)
                [ "y", "yes", "true" ]
    in
    OpenApi.Generate.file
        { namespace = moduleName
        , generateTodos = generateTodos
        }
        apiSpec
        |> Result.mapError FatalError.fromString
        |> BackendTask.fromResult
        |> BackendTask.andThen
            (\( decls, warnings ) ->
                warnings
                    |> List.map logWarning
                    |> BackendTask.combine
                    |> BackendTask.map (\_ -> decls)
            )
        |> BackendTask.andThen
            (\{ contents } ->
                let
                    outputPath : String
                    outputPath =
                        filePath
                            |> String.split "/"
                            |> UrlPath.join
                            |> UrlPath.toRelative
                in
                Pages.Script.writeFile
                    { path = outputPath
                    , body = contents
                    }
                    |> BackendTask.mapError
                        (\error ->
                            FatalError.fromString <|
                                Ansi.Color.fontColor Ansi.Color.brightRed <|
                                    case error.recoverable of
                                        Pages.Script.FileWriteError ->
                                            "Uh oh! Failed to write file"
                        )
                    |> BackendTask.map (\_ -> outputPath)
            )
        |> BackendTask.andThen (\outputPath -> Pages.Script.log ("SDK generated at " ++ outputPath))


logWarning : String -> BackendTask.BackendTask FatalError.FatalError ()
logWarning warning =
    Pages.Script.log <|
        Ansi.Color.fontColor Ansi.Color.brightYellow "Warning: "
            ++ warning
