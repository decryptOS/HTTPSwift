//
//  HTTPSession.swift
//  HTTPSwift
//
//  Created by Johannes Roth on 07.07.17.
//
//

import CCurl
import Dispatch
import Foundation

#if os(macOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

public enum HTTPRequestMethod : String {
    case GET = "GET"
    case POST = "POST"
}

public struct HTTPResponse {
    public var statusCode: Int
    public var data: Data
}

public enum HTTPRequestError: Error {
    case curl(code: Int, description: String)
}

public struct HTTPAuthenticationMethod: OptionSet {
    public static let none = HTTPAuthenticationMethod(rawValue: 0) /* CURLAUTH_NONE */
    public static let basic = HTTPAuthenticationMethod(rawValue: 1 << 0) /* CURLAUTH_BASIC */
    public static let digest = HTTPAuthenticationMethod(rawValue: 1 << 1) /* CURLAUTH_DIGEST */
    public static let negotiate = HTTPAuthenticationMethod(rawValue: 1 << 2) /* CURLAUTH_NEGOTIATE */
    public static let ntlm = HTTPAuthenticationMethod(rawValue: 1 << 3) /* CURLAUTH_NTLM */
    public static let digestIE = HTTPAuthenticationMethod(rawValue: 1 << 4) /* CURLAUTH_DIGEST_IE */
    
    public static let any = HTTPAuthenticationMethod(rawValue: ~HTTPAuthenticationMethod.digestIE.rawValue) /* CURLAUTH_ANY */
    public static let anySafe = HTTPAuthenticationMethod(rawValue: ~(HTTPAuthenticationMethod.basic.rawValue | HTTPAuthenticationMethod.digestIE.rawValue)) /* CURLAUTH_ANY */
    
    public var rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public class HTTPSession {
    public var method: HTTPRequestMethod
    public var url: URL
    
    public let skipPeerVerification: Bool
    public let skipHostnameVerification: Bool
    
    private var _handle: UnsafeMutableRawPointer!
    
    private var _headersDirty: Bool = false
    private var _chunk: UnsafeMutablePointer<curl_slist>!
    
    private var _bodyDataDirty: Bool = false
    
    public var bodyData: Data? {
        didSet {
            _bodyDataDirty = true
        }
    }
    
    public var connectTimeout: Int {
        didSet {
            curl_easy_setopt_long(_handle, CURLOPT_CONNECTTIMEOUT, connectTimeout)
        }
    }
    
    public var resourceTimeout: Int {
        didSet {
            curl_easy_setopt_long(_handle, CURLOPT_TIMEOUT, resourceTimeout)
        }
    }
    
    public init(method: HTTPRequestMethod = .GET, url: URL, skipPeerVerification: Bool = false, skipHostnameVerification: Bool = false) {
        self.method = method
        self.url = url
        
        self.skipPeerVerification = skipPeerVerification
        self.skipHostnameVerification = skipHostnameVerification
        
        self.connectTimeout = 300
        self.resourceTimeout = 0
        
        _handle = curl_easy_init()
        
        curl_easy_setopt_long(_handle, CURLOPT_NOSIGNAL, 1)
        
        curl_easy_setopt_string(_handle, CURLOPT_URL, url.absoluteString)
        curl_easy_setopt_bool(_handle, CURLOPT_VERBOSE, false)
        
        curl_easy_setopt_bool(_handle, CURLOPT_SSL_VERIFYPEER, !skipPeerVerification)
        curl_easy_setopt_bool(_handle, CURLOPT_SSL_VERIFYHOST, !skipHostnameVerification)
        
        curl_easy_setopt_string(_handle, CURLOPT_CUSTOMREQUEST, method.rawValue)
        
        #if swift(>=3.1)
            curl_easy_setopt_write_func(_handle, CURLOPT_WRITEFUNCTION, _curl_helper_write_callback)
        #else
            let callback: @convention(c) (UnsafeMutableRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { buffer, size, nmemb, userp in
                return _curl_helper_write_callback(buffer, size, nmemb, userp)
            }
            
            curl_easy_setopt_write_func(_handle, CURLOPT_WRITEFUNCTION, callback)
        #endif
    }
    
    deinit {
        curl_easy_cleanup(_handle)
    }
    
    public func authenticate(using method: HTTPAuthenticationMethod, username: String, password: String) {
        curl_easy_setopt_string(_handle, CURLOPT_USERNAME, username)
        curl_easy_setopt_string(_handle, CURLOPT_PASSWORD, password)
        curl_easy_setopt_long(_handle, CURLOPT_HTTPAUTH, method.rawValue)
    }
    
    public func clearHeaderFields() {
        _chunk = nil
        
        _headersDirty = true
    }
    
    public func setValue(_ value: String, forHeaderField field: String) {
        _chunk = curl_slist_append(_chunk, "\(field): \(value)")
        
        _headersDirty = true
    }
    
    public func performAsync(on queue: DispatchQueue, completionHandler: @escaping (Error?, HTTPResponse?) -> Void) {
        queue.async {
            do {
                let response = try self.perform()
                completionHandler(nil, response)
            } catch {
                completionHandler(error, nil)
            }
        }
    }
    
    public func perform() throws -> HTTPResponse {
        if _headersDirty {
            curl_easy_setopt_ptr_slist(_handle, CURLOPT_HTTPHEADER, _chunk)
            _headersDirty = false
        }
        
        if _bodyDataDirty {
            _ = bodyData?.withUnsafeMutableBytes { (pointer) in
                curl_easy_setopt_ptr_char(_handle, CURLOPT_POSTFIELDS, pointer)
            }
            
            _bodyDataDirty = false
        }
        
        var chunk = _curl_helper_memory_struct()
        chunk.memory = malloc(1)
        chunk.size = 0
        
        defer {
            free(chunk.memory)
        }
        
        _ = withUnsafePointer(to: &chunk) { pointer in
            curl_easy_setopt_write_data(_handle, CURLOPT_WRITEDATA, UnsafeMutableRawPointer(mutating: pointer))
        }
        
        let ret = curl_easy_perform(_handle)
        
        if ret != CURLE_OK {
            let errorCode: Int
            #if swift(>=3.1.1)
                errorCode = Int(truncatingBitPattern: UInt64(ret.rawValue))
            #else
                errorCode = Int(ret.rawValue)
            #endif
            
            let description = String(cString: curl_easy_strerror(ret), encoding: .ascii)!
            
            throw HTTPRequestError.curl(code: errorCode, description: description)
        }
        
        var statusCode: Int = 0
        _ = withUnsafePointer(to: &statusCode) { pointer in
            curl_easy_getinfo_long(_handle, CURLINFO_RESPONSE_CODE, UnsafeMutablePointer(mutating: pointer))
        }
        
        let data = Data(bytes: chunk.memory, count: chunk.size)
        
        return HTTPResponse(statusCode: statusCode, data: data)
    }
}

