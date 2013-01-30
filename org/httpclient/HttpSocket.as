/**
 * Copyright (c) 2007 Gabriel Handford
 * See LICENSE.txt for full license information.
 */
package org.httpclient {
  
  import com.adobe.net.URI;
  //import com.hurlant.crypto.tls.TLSSocket;
  
  import flash.net.Socket;
  import flash.utils.ByteArray;
  import flash.utils.Timer;
  
  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.events.IOErrorEvent;
  import flash.events.SecurityErrorEvent;
  import flash.events.ProgressEvent;  
  import flash.errors.EOFError;
  import flash.events.TimerEvent;
  
  import org.httpclient.io.HttpRequestBuffer;
  import org.httpclient.io.HttpResponseBuffer;
  import org.httpclient.io.HttpBuffer;
  
  import org.httpclient.events.*;
  
  import flash.external.ExternalInterface;
  /**
   * HTTP Socket.
   *  
   * Follow the HTTP 1.1 spec: http://www.w3.org/Protocols/rfc2616/rfc2616.html
   */
  public class HttpSocket {
    
    public static const DEFAULT_HTTP_PORT:uint = 80;   
    public static const DEFAULT_HTTPS_PORT:uint = 443; 
    public static const HTTP_VERSION:String = "1.1";
    
    // Socket or TLSSocket
    private var _socket:*; 
    
    // Event dispatcher
    private var _dispatcher:EventDispatcher;

    // Timer
    private var _timer:HttpTimer;
    
    // Internal callbacks
    private var _onConnect:Function;
    
    // Buffers
    private var _requestBuffer:HttpRequestBuffer;
    private var _responseBuffer:HttpResponseBuffer;    
    
    private var _proxy:URI;
    
    private var _closed:Boolean;
        
    /**
     * Create HTTP socket.
     *  
     * @param dispatcher Event dispatcher
     * @param timeout Timeout (in millis); Defaults to 60 seconds.
     */
    public function HttpSocket(dispatcher:EventDispatcher, timeout:Number = 60000, proxy:URI = null) {
      _dispatcher = dispatcher;
      _timer = new HttpTimer(timeout, onTimeout);
      _proxy = proxy;
    }
    
    /**
     * Create the socket.
     * Create Socket or TLSSocket depending on URI scheme (http or https).
     */
    protected function createSocket(secure:Boolean = false):void {      
      _socket = new Socket();
      _socket.addEventListener(Event.CONNECT, onConnect);       
      _socket.addEventListener(Event.CLOSE, onClose);
      _socket.addEventListener(IOErrorEvent.IO_ERROR, onIOError);
      _socket.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
      _socket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
    }
    
    /**
     * Default port.
     */
    public function getDefaultPort(secure:Boolean = false):uint {
      if (secure) return DEFAULT_HTTPS_PORT;
      return DEFAULT_HTTP_PORT;
    }
    
    /**
     * Close socket.
     */
    public function close():void {
      if (_closed) return;
      _closed = true;
      Log.debug("Called close");
      _timer.stop();
      // Need to check if connected (otherwise closing on unconnected socket throws error)
      if (_socket && _socket.connected) {
        _socket.close();
        _socket = null;
      }
      
      // Dispatch instead of calling onClose which is reserver for socket close notification
      //onClose(new Event(Event.CLOSE));
      _dispatcher.dispatchEvent(new Event(Event.CLOSE));
    }
    
    /**
     * Initiate the connection (if not connected) and send the request.
     * @param request HTTP request
     */
    public function request(uri:URI, request:HttpRequest):void {
      var onConnect:Function = function(event:Event):void {
        
        _dispatcher.dispatchEvent(new HttpRequestEvent(request, null, HttpRequestEvent.CONNECT));
        
        
        sendRequest(uri, request);
        
      };
      
      // Connect
      connect(uri, onConnect);
    }
   
    /**
     * Connect (to URI).
     * @param uri Resource to connect to
     * @param onConnect On connect callback
     */
    protected function connect(uri:URI, onConnect:Function = null):void {
      _onConnect = onConnect;

      // Create the socket
      var secure:Boolean = (uri.scheme == "https");
      createSocket(secure);

      // Start timer
      _timer.start();
      
      // Connect
      var port:int = (_proxy) ? Number(_proxy.port) : Number(uri.port);
      if (!port) port = getDefaultPort(secure);
      
      var host:String = (_proxy) ? _proxy.authority : uri.authority;
      Log.debug("Connecting: host: " + host + ", port: " + port);
        
      _socket.connect("114.80.230.221", port); 
      
    }
    
    /**
     * Send request.
     * @param uri URI
     * @param request Request to write
     */
    protected function sendRequest(uri:URI, request:HttpRequest):void {               
      // Prepare response buffer
      _responseBuffer = new HttpResponseBuffer(request.hasResponseBody, onResponseHeader, onResponseData, onResponseComplete);
      
      Log.debug("Request URI: " + uri + " (" + request.method + ")");
      var headerBytes:ByteArray = request.getHeader(uri, _proxy, HTTP_VERSION);
      
      // Debug
      Log.debug("Header:\n" + headerBytes.readUTFBytes(headerBytes.length));
      headerBytes.position = 0;
      _socket.writeBytes(headerBytes);      
      _socket.flush();
      _timer.reset();
       if (request.hasRequestBody) {
            _requestBuffer = new HttpRequestBuffer(request.body);
            Log.debug("Sending request data");
            var bytesTotalLength:Number = 0;
            while (_requestBuffer.hasData) {
                var bytes:ByteArray = _requestBuffer.read();
                if (bytes.length > 0) {
                    bytesTotalLength += bytes.length;
                    onRequestProgress(bytesTotalLength);
                    _socket.writeBytes(bytes);
                    _timer.reset();
                    _socket.flush();
                }
            }
      }
      
      Log.debug("Send request done");
      headerBytes.position = 0;
      onRequestComplete(request, headerBytes.readUTFBytes(headerBytes.length));
    }
    
    

    /**
     * Socket data available.
     */
    private function onSocketData(event:ProgressEvent):void {
      while (_socket && _socket.connected && _socket.bytesAvailable) {        
        _timer.reset();
        try {           
          
          // Load data from socket
          var bytes:ByteArray = new ByteArray();
          _socket.readBytes(bytes, 0, _socket.bytesAvailable);                       
          bytes.position = 0;
            
          // Write to response buffer
          _responseBuffer.writeBytes(bytes);
          
        } catch(e:EOFError) {
          Log.debug("EOF");
          _dispatcher.dispatchEvent(new HttpErrorEvent(HttpErrorEvent.ERROR, false, false, "EOF", 1));          
          break;
        }                           
      }
    }
    
    // Called from 
    private function onResponseComplete(response:HttpResponse):void {
      Log.debug("Response complete");
      close(); // Don't close TLSSocket; it has a bug I think
      onComplete(response);
    }
    
    //
    // Events (Custom listeners)
    //
    
    private function onRequestComplete(request:HttpRequest, header:String):void {      
      _dispatcher.dispatchEvent(new HttpRequestEvent(request, header));
    }
    
    private function onResponseHeader(response:HttpResponse):void {
      Log.debug("Response: " + response.code);
      _dispatcher.dispatchEvent(new HttpStatusEvent(response));
    }
    
    private function onResponseData(bytes:ByteArray):void {
      _dispatcher.dispatchEvent(new HttpDataEvent(bytes));
    }
    
    private function onComplete(response:HttpResponse):void {
      _timer.stop();
      _dispatcher.dispatchEvent(new HttpResponseEvent(response));
    }

    private function onRequestProgress(load:Number):void{
       _dispatcher.dispatchEvent(new HttpProgressEvent(load));
    }
    
    private function onTimeout(idleTime:Number):void {
      _dispatcher.dispatchEvent(new HttpErrorEvent(HttpErrorEvent.TIMEOUT_ERROR, false, false, "Timeout", 0));
      close();
    }
    
    //
    // Events (Socket listeners)
    //

    private function onConnect(event:Event):void {   
      // Internal callback (does dispatch as well)
      if (_onConnect != null) _onConnect(event);            
    }
    
    private function onClose(event:Event):void {
      _dispatcher.dispatchEvent(event.clone());
      
      // If we are not a chunked response and we didn't get content length
      // then we just take it as we get it and assume the server closed the connection
      // when there is no more data.
      // TODO(gabe): Not sure if this is the correct behavior
      if (_responseBuffer) {
        var response:HttpResponse = _responseBuffer.header; 
        if (response && response.contentLength == -1 && !response.isChunked) {
          onComplete(response);
        }
      }
    }
    
    private function onIOError(event:IOErrorEvent):void { 
      ExternalInterface.call("alert", "IO错误!");
      if (_closed) return;
      close();
      _dispatcher.dispatchEvent(event.clone());
    }

    private function onSecurityError(event:SecurityErrorEvent):void {
      if (_closed) return;
      close();
      _dispatcher.dispatchEvent(event.clone());
    }
  }
}