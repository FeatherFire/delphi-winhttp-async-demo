unit Unit1;

interface

uses
  Winapi.Windows, WinHTTP,
  System.SysUtils, System.StrUtils, System.SyncObjs,
  Vcl.Forms, Vcl.StdCtrls, Vcl.Controls, System.Classes;

const
  // copied from WinApi.WinInet
  INTERNET_MAX_HOST_NAME_LENGTH = 256;
  INTERNET_MAX_USER_NAME_LENGTH = 128;
  INTERNET_MAX_PASSWORD_LENGTH = 128;
  INTERNET_MAX_PATH_LENGTH = 2048;
  INTERNET_MAX_SCHEME_LENGTH = 32;

  // undefined in WinHttp - values from: https://www.magnumdb.com
  WINHTTP_CALLBACK_STATUS_GETPROXYFORURL_COMPLETE = 16777216;
  WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE = 33554432;
  WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE = 67108864;

  // from: https://www.magnumdb.com
  LB_ADDSTRING : UINT = 384;
  WM_SETTEXT : UINT = 12;

  bAutomaticProxyConfiguration: Boolean = False;
  bForceTLS13: Boolean = False;
	WINHTTP_ACCESS_TYPE_DEFAULT_PROXY   = 0;
  WINHTTP_ACCESS_TYPE_NO_PROXY        = 1;
	WINHTTP_ACCESS_TYPE_NAMED_PROXY			= 3;
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;
  WINHTTP_AUTOPROXY_ALLOW_STATIC = 512;

  STRUCT_TYPE_NO_CONTEXT = 0;
  STRUCT_TYPE_REQ_CONTEXT = 1;

  GET_REQ = 1;
  POST_REQ = 2;         // not used in demo, future use

  NOT_BUSY_STATE = 0;
  BUSY_STATE = 1;

type
//  Structure used for storing the context for the asynchronous calls. The
//  pointer to this structure is the context (DWORD) for the callback.
//  It is a way to reference such things as the session, connection and
//  request handles.  It is especially important for tracking the number
//  of bytes transferred while downloading the resource.  This approach
//  allows having only one connection to the server while doing callback
//  processing for multiple request handles using that connection.
  REQ_CONTEXT_struct = record
    dwStructType: DWORD;        // 1: Request, 2+: Undefined/future
    dwAction: DWORD;            // 1: Get, 2: Post/future
    dwState: DWORD;             // flag situation where data read is not complete
    hSession: HINTERNET;
    hConnect: HINTERNET;
    hRequest: HINTERNET;
    dwSize: DWORD;              // Size of the latest data block
    dwTotalSize: DWORD;         // Size of the total data
    lpBuffer: PByte;            // Buffer for storing read data
    memo: string[255];          // for debugging, or future use
  end;
  REQ_CONTEXT_struct_pointer  = ^REQ_CONTEXT_struct;

  WINHTTP_ASYNC_RESULT = record
    dwResult: DWORD_PTR;  // indicates which async API has encountered an error
    dwError: DWORD;       // the error code if the API failed
  end;
  TWinHttpAsyncResult = WINHTTP_ASYNC_RESULT;
  PWinHttpAsyncResult = ^TWinHttpAsyncResult;

  TForm1 = class(TForm)
    ListBoxProgress: TListBox;
    Label1: TLabel;
    Label2: TLabel;
    EditURL: TEdit;
    Label3: TLabel;
    Label4: TLabel;
    BtnExit: TButton;
    CheckBoxAutoProxyDetect: TCheckBox;
    CheckBoxForceTLS_1_3: TCheckBox;
    BtnSendRequest: TButton;
    MemoResource: TMemo;       // use TMemo instead of TEdit because
    MemoHeaders: TMemo;        // TEdit appears to have 43679 character limit

    procedure FormActivate(Sender: TObject);
    procedure BtnExitClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure BtnSendRequestClick(Sender: TObject);

  private
    { Private declarations }
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

  LogHeadersHandle: HWND;      // listbox handle, for addressing messages
  LogResourceHandle: HWND;     // listbox handle, for addressing messages
  LogProgressHandle: HWND;     // listbox handle, for addressing messages

  ReqContext: REQ_CONTEXT_struct;             // rcContext, rcContext2 not used
  PtrReqContext: REQ_CONTEXT_struct_pointer;

  URL: String;                 // e.g., "http://github.com"
  Host: String;                // host name
  Port: Word;                  // internet port, 80 for ws, 443 for wss, or as specified
  Path: String;                // requires at least "/"
  ExtraInfo: String;           // e.g., "?stuff=something"
  Protocol: String;            // "http" or "https"
  SubProtocol: String;         // "sub-protocol" per websocket RFC, e.g. WASM or echo-protocol
  ErrorText: String;           // last error
  AgentHeader: String;         // "e.g., Delphi  Client Test"
  PathWithExtraInfo: String;   // send to include any query text

  SessionHandle: HINTERNET;
  ConnectionHandle: HINTERNET;
  GET_RequestHandle: HINTERNET;
  POST_RequestHandle: HINTERNET;
  WebSocketHandle: HINTERNET;

  URLComponents: TURLComponents;

  pCallback: TWinHttpStatusCallback;     // address of callback procedure
  pCallbackPointer: PWinHttpStatusCallback = Nil; // returned by function

  CallBackCritSec: TCriticalSection;     // g_CallBackCritSec for unlocking the "Send Request" button

  procedure PollingCallbackImplementation(InternetHandle: HINTERNET; dwContext: DWORD;
                     dwInternetStatus: DWORD; lpvStatusInformation: Pointer;
                     dwStatusInformationLength: DWORD);   stdcall;
  procedure Cleanup( ctxt: REQ_CONTEXT_struct; msg: String );
  function SendRequest(strURL: String): Boolean;

implementation

{$R *.dfm}

procedure TForm1.BtnExitClick(Sender: TObject);
begin
  Cleanup( ReqContext, 'BtnExitClick');
  Form1.Close;
end;

procedure TForm1.BtnSendRequestClick(Sender: TObject);
var
  URL: String;
begin
  // disable button
  Form1.BtnSendRequest.Enabled := False;
  // clear outputs
  Form1.MemoHeaders.Clear;
  Form1.MemoResource.Clear;
  Form1.ListBoxProgress.Clear;
  //send requst
  URL := Form1.EditURL.Text;
  SendRequest(URL);        // function, not checking return
  Form1.BtnSendRequest.Enabled := True;
end;

function SendRequest(strURL: String): Boolean;
var
  Flag: Cardinal;                  // for WinHttpOpenRequest
  Method: String;                  // for WinHttpOpenRequest
  HeaderText: UTF8String;
  HeaderTextlength: DWORD;
  BodyText: UTF8String;
  BodyTextLength: DWORD;
  MyContext: REQ_CONTEXT_struct_pointer;  // pointer to the context structure
  dwFlags: DWORD;
  bAutomaticProxyConfiguration: Boolean;
  AutoProxyOptions: WINHTTP_AUTOPROXY_OPTIONS;
  IEProxyConfig: WINHTTP_CURRENT_USER_IE_PROXY_CONFIG;
  ProxyInfo:  WINHTTP_PROXY_INFO;
  cbProxyInfoSize: DWORD;
  bResult: Boolean;
  dwError: DWORD;
  szHost: string[255];
  fRet: Boolean;
  LogBuffer: String;  // WCHAR szBuffer[256];  line 179

  Label
  CleanupGoTo;  // follows the example, see line 507

begin
  fRet := False;

  // get URL
  if ( strURL.Length = 0 ) then  // empty
  begin
    LogBuffer := 'Missing URL';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    Result := False;
    Exit;
  end;

  //checking for automatic proxy detection set
  bAutomaticProxyConfiguration := False;
  if Form1.CheckBoxAutoProxyDetect.Checked then
  begin
    bAutomaticProxyConfiguration := True;
    LogBuffer := '->WinHttpOpen with WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY access type';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  end
  else
  begin
    LogBuffer := '->WinHttpOpen WINHTTP_ACCESS_TYPE_DEFAULT_PROXY access type';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  end;

  // Initialize URL_COMPONENTS structure.
  FillChar( URLComponents, SizeOf(TURLComponents), 0);
  with  URLComponents do
  begin
    lpszScheme := nil;
    dwSchemeLength := INTERNET_MAX_SCHEME_LENGTH;
    lpszHostName := @szHost;
    dwHostNameLength := INTERNET_MAX_HOST_NAME_LENGTH;
    lpszUserName := nil;
    dwUserNameLength := INTERNET_MAX_USER_NAME_LENGTH;
    lpszPassword := nil;
    dwPasswordLength := INTERNET_MAX_PASSWORD_LENGTH;
    lpszUrlPath := nil;
    dwUrlPathLength := INTERNET_MAX_PATH_LENGTH;
    lpszExtraInfo := nil;
    dwExtraInfoLength := INTERNET_MAX_PATH_LENGTH;
    dwStructSize := SizeOf( URLComponents);
    nPort := 0;
  end;
  // Set non zero lengths to obtain pointer to the URL Path.
  // note: if we treat this pointer as a NULL terminated string
  //       this pointer will contain Extra Info as well.

  // Crack HTTP scheme and URL
  if ( WinHttpCrackUrl(PWideChar(strURL), Length(strURL), 0, URLComponents) = False ) then
  begin
    LogBuffer := '<-- WinHttpCrackUrl failed : ' + IntToStr(GetLastError());
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;

  //protocol / scheme (at this point, should be either "http" or "https")
  if ( URLComponents.lpszScheme <> nil) AND ( URLComponents.dwSchemeLength > 0) then
  begin
    Protocol := LeftStr( URLComponents.lpszScheme,  URLComponents.dwSchemeLength);
  end
  else  // no protocol
  begin
    LogBuffer := 'Failed to parse URL (' + strURL + ') for protocol.';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  if not ( (Protocol = 'http') or (Protocol = 'https') ) then
  begin
    LogBuffer := 'Protocol must be "http" or "https".';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;

  // host
  if ( URLComponents.lpszHostName <> nil) AND ( URLComponents.dwHostNameLength > 0) then
  begin
    Host := LeftStr( URLComponents.lpszHostName,  URLComponents.dwHostNameLength);
  end
  else
  begin
    LogBuffer := 'Failed to parse URL (' + strURL + ') for host name.';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;

  // path - use "/" if blank
  if ( URLComponents.lpszUrlPath <> nil) AND ( URLComponents.dwUrlPathLength > 0) then
  begin
    Path := LeftStr( URLComponents.lpszUrlPath,  URLComponents.dwUrlPathLength);
  end
  else
  begin
    Path := '/';
  end;

  // port - if not provided, use 80/443
  if ( URLComponents.nPort > 0) then
  begin
    Port :=  URLComponents.nPort;
  end
  else
  begin
    if Protocol = 'http' then  // 80
    begin
      Port := 80;
    end;
    if Protocol = 'https' then  // 443
    begin
      Port := 443;
    end;
  end;

  // extra info, like directory and query
  if ( URLComponents.lpszExtraInfo <> nil) AND ( URLComponents.dwExtraInfoLength > 0) then
  begin
    ExtraInfo := LeftStr( URLComponents.lpszExtraInfo,  URLComponents.dwExtraInfoLength);
  end
  else
  begin
    ExtraInfo := '';
  end;

  // URL
  PathWithExtraInfo := Path + ExtraInfo;
  URL := Protocol + '://' + Host + ':' + IntToStr(Port) + PathWithExtraInfo;
  LogBuffer := 'URL is: ' + URL;
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  // Create the session handle using the default settings.
  AgentHeader := 'Delphi-WinHttpAsync-Demo';
  // Open an HTTP session.
  SessionHandle := WinHttpOpen(PWideChar(AgentHeader),
      WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      WINHTTP_NO_PROXY_NAME,
      WINHTTP_NO_PROXY_BYPASS,
      WINHTTP_FLAG_ASYNC );

  if SessionHandle = Nil then
  begin
    LogBuffer := '<-- WinHttpOpen failed : ' + IntToStr(GetLastError);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  LogBuffer := '<-- WinHttpOpen success. SessionHandle : ' + IntToStr(DWORD(SessionHandle));
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  // Install the callback function.
  // WinHttpSetStatusCallback returns pointer to previous callback, Nill (if no previous), -1 for error
  if ( pCallbackPointer = Nil ) then
  begin
    LogBuffer := '->Calling WinHttpSetStatusCallback with WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS.';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    LogBuffer := '  SessionHandle : ' + IntToStr(DWORD(SessionHandle));
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

   	// note: On success WinHttpSetStatusCallback returns the previously defined callback function.
  	// Here it should be NULL
    pCallback := WinHttpSetStatusCallback(SessionHandle, @PollingCallbackImplementation,
                   WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0);
  end;
  if ( NativeInt(@pCallback) = -1 ) then   // INTERNET_INVALID_STATUS_CALLBACK
  begin
    LogBuffer := '<-WinHttpSetStatusCallback WINHTTP_INVALID_STATUS_CALLBACK';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    LogBuffer := '  Error: ' + IntToStr(GetLastError);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  LogBuffer := '<-WinHttpSetStatusCallback succeeded';
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  // set TLS 1.3 if checked
  if ( Form1.CheckBoxForceTLS_1_3.Checked ) then
  begin
    dwFlags := WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
    WinHttpSetOption(SessionHandle, WINHTTP_OPTION_SECURE_PROTOCOLS, @dwFlags, sizeof(dwFlags));
  end;

  // Get Connection
  LogBuffer := '->Calling WinHttpConnect for host ' + Host + ' and port ' + IntToStr(Port);
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  // get connection handle
  ConnectionHandle := WinHttpConnect(SessionHandle, PWideChar(Host), Port, 0);
  if ConnectionHandle = Nil then
  begin
    LogBuffer := '<-WinHttpConnect failed : '  + IntToStr(GetLastError);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  LogBuffer := '<-WinHttpConnect  succeeded. ConnectionHandle = ' + IntToStr(DWORD(ConnectionHandle));
   SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  if bAutomaticProxyConfiguration then
  begin
    LogBuffer := '->Calling WinHttpGetIEProxyConfigForCurrentUser';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    if (WinHttpGetIEProxyConfigForCurrentUser(IEProxyConfig)) then
    begin
      LogBuffer := '<-WinHttpGetIEProxyConfigForCurrentUser succeeded';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      //
      // If IE is configured to autodetect, then we'll autodetect too
      //
      if (IEProxyConfig.fAutoDetect) then
      begin
        LogBuffer := 'Automatically detect settings set';
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
        AutoProxyOptions.dwFlags := WINHTTP_AUTOPROXY_AUTO_DETECT;
        //
        // Use both DHCP and DNS-based autodetection
        //
        AutoProxyOptions.dwAutoDetectFlags := WINHTTP_AUTO_DETECT_TYPE_DHCP and WINHTTP_AUTO_DETECT_TYPE_DNS_A;
      end;
      //
      // If there's an autoconfig URL stored in the IE proxy settings, save it
      //
      if (IEProxyConfig.lpszAutoConfigUrl <> Nil) then
      begin
        LogBuffer := 'Autoconfiguration url set to : ' + PWideCHar(IEProxyConfig.lpszAutoConfigUrl);
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
        AutoProxyOptions.dwFlags := AutoProxyOptions.dwFlags and WINHTTP_AUTOPROXY_CONFIG_URL;
        AutoProxyOptions.lpszAutoConfigUrl := IEProxyConfig.lpszAutoConfigUrl;
      end;
      //
      // If there's a static proxy
      //
      if (IEProxyConfig.lpszProxy <> Nil) then
      begin
        LogBuffer := 'Static proxy set to : ' + PWideChar(IEProxyConfig.lpszProxy);
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
        AutoProxyOptions.dwFlags := AutoProxyOptions.dwFlags and WINHTTP_AUTOPROXY_ALLOW_STATIC;
      end;

      // get proxy
      LogBuffer := '->Calling WinHttpGetProxyForUrl';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
			bResult := WinHttpGetProxyForUrl(SessionHandle, URLComponents.lpszScheme,
                                     AutoProxyOptions, proxyInfo);
      if bResult = False then
      begin
        dwError := GetLastError();
        LogBuffer := '<-WinHttpGetProxyForUrl failed : ' + IntToStr(dwError);
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end
      else
      begin
        if (proxyInfo.lpszProxy <> Nil) then
        begin
          LogBuffer := 'Proxy :' + PWideChar(proxyInfo.lpszProxy);
          SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
        end;
        if (proxyInfo.lpszProxyBypass <> Nil) then
        begin
          LogBuffer := 'Proxy bypass :' + PWideChar(proxyInfo.lpszProxyBypass);
          SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
        end;
      end;

			if (proxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_DEFAULT_PROXY) then
      begin
        LogBuffer := 'WINHTTP_ACCESS_TYPE_DEFAULT_PROXY';
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end;
  		if (proxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_NO_PROXY) then
      begin
        LogBuffer := 'WINHTTP_ACCESS_TYPE_NO_PROXY';
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end;
  		if (proxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_NAMED_PROXY) then
      begin
        LogBuffer := 'WINHTTP_ACCESS_TYPE_NAMED_PROXY';
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end;

      // Calling WinHttpSetOption WINHTTP_OPTION_PROXY - line 397
      LogBuffer := '->Calling WinHttpSetOption WINHTTP_OPTION_PROXY';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      if ( WinHttpSetOption(SessionHandle, WINHTTP_OPTION_PROXY,@proxyInfo, sizeof(proxyInfo)) = False) then
      begin
        dwError := GetLastError();
        LogBuffer := '<-- WinHttpSetOption WINHTTP_OPTION_PROXY failed : ' + IntToStr(dwError);
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end
      else
      begin
        LogBuffer := '<-- WinHttpSetOption WINHTTP_OPTION_PROXY success';
        SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      end;
    end;
  end;

  // Prepare OpenRequest flag - SSL or not
  Flag := 0;  // "http"
  if ( Protocol = 'https' ) then
  begin
    Flag := WINHTTP_FLAG_SECURE;  // "https"
  end;
  // Create request handle - use 0 for null pointers to empty strings: Version, Referrer, AcceptTypes
  Method := 'GET';                  // for first WinHttpOpenRequest

  LogBuffer := '->Calling WinHttpOpenRequest';
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  GET_RequestHandle := WinHttpOpenRequest(ConnectionHandle, PWideChar(Method),
                       pWideChar(PathWithExtraInfo), Nil, Nil, Nil, Flag);

  If GET_RequestHandle = Nil Then
  begin
    LogBuffer := '<-WinHttpOpenRequest failed : ' + IntToStr(GetLastError);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  LogBuffer := '<-WinHttpOpenRequest succeeded. RequestHandle : ' + IntToStr(DWORD(GET_RequestHandle));
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  // set proxy info
  cbProxyInfoSize := SizeOf(ProxyInfo);
  LogBuffer := '->WinHttpQueryOption with  WINHTTP_OPTION_PROXY';
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  if ( WinHttpQueryOption( GET_RequestHandle, WINHTTP_OPTION_PROXY,
		                         &ProxyInfo, &cbProxyInfoSize) = False )  then
  begin

    // Exit if setting the proxy info failed. -  I don't see that code?????
    LogBuffer := '<-WinHttpQueryOption WINHTTP_OPTION_PROXY failed : ' + IntToStr(GetLastError());
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;       // not present in example
  end
  else
  begin
    LogBuffer := '<-WinHttpQueryOption WINHTTP_OPTION_PROXY suceeded';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    LogBuffer := 'Proxy : ' + PWideChar(ProxyInfo.lpszProxy);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    LogBuffer := 'ProxyBypass : ' + PWideChar(ProxyInfo.lpszProxyBypass);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    // WinHttpOpen dwAccessType values (also for WINHTTP_PROXY_INFO::dwAccessType)
		//    WINHTTP_ACCESS_TYPE_DEFAULT_PROXY       0
		//    WINHTTP_ACCESS_TYPE_NO_PROXY            1
		//    WINHTTP_ACCESS_TYPE_NAMED_PROXY					3
    LogBuffer := '  AccessType : ' + IntToStr(ProxyInfo.dwAccessType);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

		if (ProxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_DEFAULT_PROXY) then
    begin
      LogBuffer := 'WINHTTP_ACCESS_TYPE_DEFAULT_PROXY';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    end;
		if (ProxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_NO_PROXY) then
    begin
      LogBuffer := 'WINHTTP_ACCESS_TYPE_NO_PROXY';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    end;
		if (ProxyInfo.dwAccessType = WINHTTP_ACCESS_TYPE_NAMED_PROXY) then
    begin
      LogBuffer := 'WINHTTP_ACCESS_TYPE_NAMED_PROXY';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    end;
  end;

  // context
  ReqContext.dwStructType := STRUCT_TYPE_REQ_CONTEXT;
  ReqContext.hSession := SessionHandle;
  ReqContext.hConnect := ConnectionHandle;
  ReqContext.hRequest := GET_RequestHandle;
  ReqContext.dwAction := GET_REQ;
  ReqContext.dwState := NOT_BUSY_STATE;
  ReqContext.dwSize := 0;
  ReqContext.dwTotalSize := 0;
  ReqContext.lpBuffer := Nil;
  ReqContext.memo := 'RequestReady';           // optional for this demo
  MyContext := @ReqContext;

  // see: https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpsendrequest
  // NOT TESTED - if we want to send headers...
  HeaderText := 'Host: ' + Host + #13#10;     // possibly redundant, WinHttp may add automatically??
  HeaderText := HeaderText + 'DummyEntry: X';
  // add other headers here - each line needs line end, except last line
  HeaderTextLength := length(HeaderText);   // or, set this to "-1" so function figures it out automatically
  // NOT TESTED - if we want to send POST, etc. with body data...
  BodyText := 'something';
  BodyTextLength := Length(BodyText);
  // WinHttpSendRequest(GET_RequestHandle, HeaderText, HeaderTextLength, BodyText,
  //                                     BodyTextLength, BodyTextLength, DWORD(MyContext))) then

  // tested - no headers, no body data
  LogBuffer := '->Calling WinHttpSendRequest. RequestHandle : ' + IntToStr(DWORD(GET_RequestHandle));
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  if ( WinHttpSendRequest(GET_RequestHandle, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
              WINHTTP_NO_REQUEST_DATA, 0, 0, DWORD(MyContext)) =  False ) then
  begin
    LogBuffer := '<-WinHttpSendRequest failed : ' +  IntToStr(GetLastError);
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    GoTo CleanupGoTo;
  end;
  LogBuffer := '<-WinHttpSendRequest succeeded';
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  fRet := True;

CleanupGoTo:
  begin
    if ( fRet = False ) then
    begin
      LogBuffer := 'Cleanup exit...';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      // Close the session handle.
      LogBuffer := '->WinHttpCloseHandle SessionHandle (' + IntToStr(DWORD(SessionHandle));
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      WinHttpCloseHandle(SessionHandle);
    end;
    Exit(fRet);
  end;
end;


procedure Cleanup( ctxt: REQ_CONTEXT_struct; msg: String );  // line 535
var
  LogBuffer: String;  // "szBuffer" at line 537

begin
  // wait until any reading is done
  LogBuffer := 'Cleanup Delayed';
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  if ctxt.dwState = BUSY_STATE then
  begin
    while  ctxt.dwState = BUSY_STATE do
    begin
      Sleep(500);
    end;
  end;

  LogBuffer := 'Cleanup ' + msg;
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

  ctxt.dwStructType := STRUCT_TYPE_NO_CONTEXT;    // maybe pointless

  // clear request handle
  if ( ctxt.hRequest <> Nil ) then
  begin
    LogBuffer := '->WinHttpSetStatusCallback NULL';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  	WinHttpSetStatusCallback(ctxt.hRequest, Nil, 0, 0);   // cancel callbacks
    LogBuffer := '<--WinHttpSetStatusCallback NULL';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    LogBuffer := '->WinHttpCloseHandle RequestHandle (' + IntToStr(DWORD(ctxt.hRequest)) + ')';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    WinHttpCloseHandle(ctxt.hRequest);
    LogBuffer := '<--WinHttpCloseHandle';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    ctxt.hRequest := Nil;
  end;
  if ( ReqContext.hRequest <> Nil ) then
  begin
    ReqContext.hRequest := Nil;   // is this necessary or a bad idea?????????????????????
  end;
  // clear connection handle
  if ( ctxt.hConnect <> Nil ) then
  begin
    LogBuffer := '->WinHttpCloseHandle ConnectHandle (' + IntToStr(DWORD(ctxt.hConnect)) + ')';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    WinHttpCloseHandle(ctxt.hConnect);
    LogBuffer := '<--WinHttpCloseHandle';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
    ctxt.hConnect := Nil;
  end;
  if ( ReqContext.hConnect <> Nil ) then
  begin
    ReqContext.hConnect := Nil;
  end;
  // clear buffer pointer
  FreeMem(ctxt.lpBuffer);
  ctxt.lpBuffer := Nil;
  ReqContext.lpBuffer := Nil;
end;


procedure TForm1.FormActivate(Sender: TObject);
begin
  Form1.EditURL.Text := 'http://www.bing.com';

  // Initialize the first context value - just because...
  ReqContext.dwStructType := 0;
  ReqContext.hSession := Nil;
  ReqContext.hConnect := Nil;
  ReqContext.hRequest := Nil;
  ReqContext.dwAction := 0;
  ReqContext.dwState := 0;  // future
  ReqContext.lpBuffer := Nil;
  ReqContext.memo := 'Initial';           // optional for this demo

  // get handles for Windows messaging
  LogHeadersHandle := Form1.MemoHeaders.Handle;
  LogResourceHandle := Form1.MemoResource.Handle;
  LogProgressHandle := Form1.ListBoxProgress.Handle;

end;

procedure TForm1.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  //
end;


function Header( ctxt: REQ_CONTEXT_struct ): Boolean;    // line 586
var
  dwSize: DWORD;
  dwErr: DWORD;
  lpOutBuffer: PChar;   // wide char, 2 bytes per character
  strTemp: String;
  LogBuffer: String;  // WCHAR szBuffer[256];  line 591

begin
  // claim a buffer length of zero so function will produce an expected error
  // of  ERROR_INSUFFICIENT_BUFFER
  dwSize := 0;
  // Use WinHttpQueryHeaders to obtain the size of the buffer.
  if ( WinHttpQueryHeaders( ctxt.hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                       WINHTTP_HEADER_NAME_BY_INDEX, Nil, dwSize,
                       WINHTTP_NO_HEADER_INDEX) = False ) then
  begin
    dwErr :=  GetLastError();
    if ( dwErr <> ERROR_INSUFFICIENT_BUFFER ) then
    begin
      Exit(False);
    end;
  end;

  // Allocate memory for the buffer.
  lpOutBuffer := AllocMem( dwSize );
  // Use WinHttpQueryHeaders to obtain the header buffer.
  if  (WinHttpQueryHeaders( ctxt.hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                            WINHTTP_HEADER_NAME_BY_INDEX, lpOutBuffer, dwSize,
                            WINHTTP_NO_HEADER_INDEX) = False ) then
  begin
    dwErr :=  GetLastError();
    LogBuffer := 'Header Error: ' + IntToStr( dwErr );
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
  end
  else   //we have header info
  begin
    LogBuffer :=  UTF8ToString( lpOutBuffer );    // conversion probably not needed
    SendMessageW( LogHeadersHandle, WM_SETTEXT, 0, NativeUInt(PWideChar(LogBuffer)));
  end;
  // Free the allocated memory.
  FreeMem(lpOutBuffer);
  Exit(True);
end;


function QueryData( var ctxt: REQ_CONTEXT_struct ): Boolean;
var
  dwErr: DWORD;
  LogBuffer: String;  // WCHAR szBuffer[256];  line 635
begin
  ctxt.memo := 'Call: WinHttpQueryDataAvailable';

  // Check for available data.
  if (WinHttpQueryDataAvailable( ctxt.hRequest, Nil) = False) then
  begin
      // If a synchronous error occured, display the error.
      // Otherwise the query is successful or asynchronous.
      dwErr := GetLastError();
      LogBuffer := 'Error ' + IntToStr(dwErr) + ' encountered.';
      SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));
      Exit(False);
  end;
  Exit(True);
end;

procedure TransferAndDeleteBuffers( var ctxt: REQ_CONTEXT_struct; lpReadBuffer: PByte; dwBytesRead: DWORD);
var
  lpOldBuffer: PByte;

begin
  ctxt.dwSize := dwBytesRead;
  if ( ctxt.lpBuffer = Nil ) then  // there is no context buffer, start one with the read data.
  begin
    ctxt.lpBuffer := lpReadBuffer;
  end
  else
  begin
    // Store the previous buffer, and create a new one big
    // enough to hold the old data and the new data.
    lpOldBuffer := ctxt.lpBuffer;
    ctxt.lpBuffer := AllocMem( ctxt.dwTotalSize + ctxt.dwSize );
    // Copy the old and read buffer into the new context buffer.
    CopyMemory( ctxt.lpBuffer, lpOldBuffer, ctxt.dwTotalSize );      // target, source, length
    CopyMemory( ctxt.lpBuffer + ctxt.dwTotalSize, lpReadBuffer, ctxt.dwSize );      // target, source, length
    // Free the memory allocated to the old and read buffers.
    FreeMem(lpOldBuffer);
    FreeMem(lpReadBuffer);
  end;
  // Keep track of the total size.
  ctxt.dwTotalSize := ctxt.dwTotalSize + ctxt.dwSize;
  ReqContext.dwTotalSize := ctxt.dwTotalSize;   // copy to original context
  ReqContext.dwSize := ctxt.dwSize;             // copy to original context
  ReqContext.lpBuffer :=  ctxt.lpBuffer;        // copy to original context

  ReqContext.memo := 'TransferAndDeleteBuffers Complete';
end;


function ReadData(ctxt: REQ_CONTEXT_struct): Boolean;    // line 681
var
  lpOutBuffer: PByte;
  dwErr: DWORD;
  LogBuffer: String;  // WCHAR szBuffer[256];  line 684
begin
  ctxt.memo := 'Entered: ReadData';
  // line 683 uses dwSize +1 ---- Why? Just to make sure buffer is bigger?
  lpOutBuffer := AllocMem( ctxt.dwSize +1 );       // AlocMem does zero-fill
  if ( WinHttpReadData(ctxt.hRequest, lpOutBuffer^, ctxt.dwSize, Nil) = False ) then  // error
  begin
    // If a synchronous error occurred, display the error.
    // Otherwise the read is successful or asynchronous.
    dwErr := GetLastError();
    LogBuffer := 'WinHttpReadData Error ' + IntToStr(dwErr) + ' encountered.';
    SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

    FreeMem(lpOutBuffer);
    ctxt.lpBuffer := Nil;      // we don't want to point to unallocated memory
    Exit(False);
  end;
  Exit(True);
end;

function GetApiErrorString(dwResult: DWORD): String;
begin
  case dwResult of
    API_RECEIVE_RESPONSE : Result := 'API_RECEIVE_RESPONSE';          // The error occurred during a call to WinHttpReceiveResponse.
    API_QUERY_DATA_AVAILABLE : Result := 'API_QUERY_DATA_AVAILABLE';  // The error occurred during a call to WinHttpQueryDataAvailable.
    API_READ_DATA : Result := 'API_READ_DATA';                        // The error occurred during a call to WinHttpReadData.
    API_WRITE_DATA : Result := 'API_WRITE_DATA';                      // The error occurred during a call to WinHttpWriteData.
    API_SEND_REQUEST : Result := 'API_SEND_REQUEST';                  // The error occurred during a call to WinHttpSendRequest.
    6 : Result := 'API_GET_PROXY_FOR_URL';                            // The error occurred during a call to WinHttpGetProxyForUrlEx.
  else
    Result := 'Unknown function';
  end;
end;


// WinCallbackImplementation
//   hInternet - The handle for which the callback function is called.
//   dwContext - Pointer to the application defined context.
//   dwInternetStatus - Status code indicating why the callback is called.
//   lpvStatusInformation - Pointer to a buffer holding callback specific data.
//   dwStatusInformationLength - Specifies size of lpvStatusInformation buffer.

procedure PollingCallbackImplementation(InternetHandle: HINTERNET; dwContext: DWORD;
                     dwInternetStatus: DWORD; lpvStatusInformation: Pointer;
                    dwStatusInformationLength: DWORD);   stdcall;

var
  REQ_CONTEXT: REQ_CONTEXT_Struct;
  P_REQ_CONTEXT:  REQ_CONTEXT_Struct_pointer;
  AsyncResult: TWinHttpAsyncResult;
  PAsyncResult: PWinHttpAsyncResult;
  LogBuffer: String;  // "szBuffer" at line 721
  strTemp: String;
  WhatProblem: DWORD;  // return from SendMessageTimeoutW

begin
  if dwContext = 0 then    // this should not happen, but we are being defensive here
  begin
    Exit;
  end;
  P_REQ_CONTEXT := Pointer(dwContext);
  // Is P_REQ_CONTEXT always valid?
  // If not, don't set REQ_CONTEXT here, set it in each applicable case?
  REQ_CONTEXT := P_REQ_CONTEXT^;

  LogBuffer := '';

  case dwInternetStatus of    // c++ switch statement at line 734

    WINHTTP_CALLBACK_STATUS_CLOSING_CONNECTION :
    // Closing the connection to the server.The lpvStatusInformation parameter is NULL.
    begin
      LogBuffer := 'CLOSING_CONNECTION (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_CONNECTED_TO_SERVER :
		// Successfully connected to the server.
		// The lpvStatusInformation parameter contains a pointer to an LPWSTR that
    // indicates the IP address of the server in dotted notation.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'CONNECTED_TO_SERVER (' + PWideChar(lpvStatusInformation) +')';
      end
      else
      begin
        LogBuffer := 'CONNECTED TO SERVER (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_CONNECTING_TO_SERVER :
		// Connecting to the server.
		// The lpvStatusInformation parameter contains a pointer to an LPWSTR that
    // indicates the IP address of the server in dotted notation.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'CONNECTING_TO_SERVER (' + PWideChar(lpvStatusInformation) +')';
      end
      else
      begin
        LogBuffer := 'CONNECTING_TO_SERVER (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_CONNECTION_CLOSED :
    // Successfully closed the connection to the server.
    // The lpvStatusInformation parameter is NULL.
    begin
      LogBuffer := 'CONNECTION_CLOSED (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE :  // line 772
    // callback after WinHttpQueryDataAvailable
    // Data is available to be retrieved with WinHttpReadData.
    // The lpvStatusInformation parameter points to a DWORD that contains the
    // number of bytes of data available.
		// The dwStatusInformationLength parameter itself is 4 (the size of a DWORD).

    begin
//      REQ_CONTEXT := P_REQ_CONTEXT^;
      REQ_CONTEXT.dwSize := DWORD(lpvStatusInformation^);
      if REQ_CONTEXT.dwState <> NOT_BUSY_STATE then
      begin
        REQ_CONTEXT.dwState := BUSY_STATE;
      end;

      // if there is no data, the process is complete.
      if ( REQ_CONTEXT.dwSize = 0) then
      begin
        LogBuffer := 'DATA_AVAILABLE Number of bytes available : ' + IntToStr(REQ_CONTEXT.dwSize) + '. All data has been read -> Displaying the data.';
        if ( REQ_CONTEXT.dwTotalSize <> 0 ) then   // All of the data has been read.  Display the data.
        begin

          // Convert the final context buffer to wide characters
          //  >>> (untested) note: in the case of binary data, only data up to the first null will be displayed <<<
          //  Not using MultiByteToWideChar, let Delphi convert with UTF8ToString
          strTemp := UTF8ToString( Pointer(REQ_CONTEXT.lpBuffer) );
          SendMessageW( LogResourceHandle, WM_SETTEXT, 0, NativeUInt(PWideChar(strTemp)));

          // Delete the remaining data buffers.
          FreeMem(REQ_CONTEXT.lpBuffer);
          REQ_CONTEXT.lpBuffer := Nil;
          REQ_CONTEXT.dwState := NOT_BUSY_STATE;

        end;
        // Close the request and connect handles for this context.
        Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE, dwSize=0');
      end
      else  // there is data, so read the next block of data.
      begin
        LogBuffer := 'DATA_AVAILABLE Number of bytes available : ' + IntToStr(REQ_CONTEXT.dwSize) + '. Reading next block of data';
        if ( ReadData( REQ_CONTEXT ) = False ) then
        begin
          LogBuffer := 'DATA_AVAILABLE Number of bytes available : ' + IntToStr(REQ_CONTEXT.dwSize) + '. ReadData returning FALSE';
          Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE, ReadData=False');
        end;
      end;
    end;

    WINHTTP_CALLBACK_STATUS_HANDLE_CREATED :
    // An HINTERNET handle has been created. The lpvStatusInformation parameter
    // contains a pointer to the HINTERNET handle.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'HANDLE_CREATED : ' + IntToStr(DWORD(lpvStatusInformation^));
      end
      else
      begin
        LogBuffer := 'HANDLE_CREATED (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING :
    // This handle value has been terminated. The lpvStatusInformation
    // parameter contains a pointer to the HINTERNET handle.
    // There will be no more callbacks for this handle.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'HANDLE_CLOSING : ' + IntToStr(DWORD(lpvStatusInformation^));
      end
      else
      begin
        LogBuffer := 'HANDLE_CLOSING (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE :  // line 843
    // callback after WinHttpReceiveResponse
    // The response header has been received and is available with WinHttpQueryHeaders.
    // The lpvStatusInformation parameter is NULL.
    begin
      LogBuffer := 'HEADERS_AVAILABLE (' + IntToStr(dwStatusInformationLength) + ')';
      REQ_CONTEXT := P_REQ_CONTEXT^;         // needed here,

      Header( REQ_CONTEXT );  // read header

      // Initialize the buffer sizes.
      REQ_CONTEXT.dwSize := 0;
      REQ_CONTEXT.dwTotalSize := 0;

      // Begin downloading the resource.
      // QueryData starts loop to ReadData, requery, until ReadData returns none.
      if ( QueryData( REQ_CONTEXT ) = False ) then
      begin
        Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE, QueryData=False');
      end;
    end;

    WINHTTP_CALLBACK_STATUS_INTERMEDIATE_RESPONSE :
    // Received an intermediate (100 level) status code message from the server.
		// The lpvStatusInformation parameter contains a pointer to a DWORD that
    // indicates the status code.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'INTERMEDIATE_RESPONSE Status code : ' + IntToStr(DWORD(lpvStatusInformation^));
      end
      else
      begin
        LogBuffer := 'INTERMEDIATE_RESPONSE (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_NAME_RESOLVED :
    // Successfully found the IP address of the server.
    // The lpvStatusInformation parameter contains a pointer to a LPWSTR that
    // indicates the name that was resolved.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'NAME_RESOLVED : ' + PWideChar(lpvStatusInformation);
      end
      else
      begin
        LogBuffer := 'NAME_RESOLVED (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_READ_COMPLETE :   // line 885
    // callback after after WinHttpReadData
    // Data was successfully read from the server. The lpvStatusInformation parameter
    // contains a pointer to the buffer specified in the call to WinHttpReadData.
		// The dwStatusInformationLength parameter contains the number of bytes read.
    begin
      REQ_CONTEXT := P_REQ_CONTEXT^;
      LogBuffer := 'READ_COMPLETE Number of bytes read : ' + IntToStr(dwStatusInformationLength);

      if (dwStatusInformationLength <> 0) then  // Copy the data and delete the buffers.
      begin
        TransferAndDeleteBuffers( REQ_CONTEXT, lpvStatusInformation, dwStatusInformationLength );
        // Check for more data.
        if ( QueryData( REQ_CONTEXT ) = False) then
        begin
          Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_READ_COMPLETE, QueryData=False');
        end;
      end;
    end;

    WINHTTP_CALLBACK_STATUS_RECEIVING_RESPONSE :
    // Waiting for the server to respond to a request.
    // The lpvStatusInformation parameter is NULL.
    begin
      LogBuffer := 'RECEIVING_RESPONSE (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_REDIRECT :
    // An HTTP request is about to automatically redirect the request. The
    // lpvStatusInformation parameter contains a pointer to an LPWSTR indicating the new URL.
		// At this point, the application can read any data returned by the server
    // with the redirect response and can query the response headers.
    // It can also cancel the operation by closing the handle
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'REDIRECT to ' + PWideChar(lpvStatusInformation);
      end
      else
      begin
        LogBuffer := 'REDIRECT (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_REQUEST_ERROR :
    // An error occurred while sending an HTTP request.
		// The lpvStatusInformation parameter contains a pointer to a
    // WINHTTP_ASYNC_RESULT structure. Its dwResult member indicates the ID of
    // the called function and dwError indicates the return value.
    begin
      PAsyncResult := lpvStatusInformation;
      AsyncResult :=  PAsyncResult^;
      begin
        LogBuffer := 'REQUEST_ERROR - error ' + IntToStr(AsyncResult.dwError) + ', result ' + GetApiErrorString(AsyncResult.dwResult);
        // Error 12019 => ERROR_WINHTTP_INCORRECT_HANDLE_STATE
        // Error 0x12027 = decimal 73767 => proxy name not resolved or host name not resolved
        Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_REQUEST_ERROR');
      end;
    end;

    WINHTTP_CALLBACK_STATUS_REQUEST_SENT :
    // Successfully sent the information request to the server.
		// The lpvStatusInformation parameter contains a pointer to a DWORD
    // indicating the number of bytes sent.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'REQUEST_SENT Number of bytes sent : ' + IntToStr(DWORD(lpvStatusInformation^));
      end
      else
      begin
        LogBuffer := 'REQUEST_SENT (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_RESOLVING_NAME :
    // Looking up the IP address of a server name. The lpvStatusInformation
    // parameter contains a pointer to the server name being resolved.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'RESOLVING_NAME ' + PWideChar(lpvStatusInformation);
      end
      else
      begin
        LogBuffer := 'RESOLVING_NAME (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_RESPONSE_RECEIVED :
    // Successfully received a response from the server.
		// The lpvStatusInformation parameter contains a pointer to a DWORD
    // indicating the number of bytes received.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'RESPONSE_RECEIVED. Number of bytes : ' + IntToStr(DWORD(lpvStatusInformation^));
      end
      else
      begin
        LogBuffer := 'RESPONSE_RECEIVED (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_SECURE_FAILURE :
		// One or more errors were encountered while retrieving a Secure Sockets
    // Layer (SSL) certificate from the server.

    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'SECURE_FAILURE (' + IntToStr(DWORD(lpvStatusInformation)) + ').';
        // 1
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_CERT_REV_FAILED ) = WINHTTP_CALLBACK_STATUS_FLAG_CERT_REV_FAILED ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'Revocation check failed to verify whether a certificate has been revoked.';
        end;
        // 2
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CERT ) = WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CERT ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'SSL certificate is invalid.';
        end;
        // 4
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_CERT_REVOKED ) = WINHTTP_CALLBACK_STATUS_FLAG_CERT_REVOKED ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'SSL certificate was revoked.';
        end;
        // 8
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CA ) = WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CA ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'The function is unfamiliar with the Certificate Authority that generated the server''s certificate.';
        end;
        // 0x10
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_CERT_CN_INVALID ) = WINHTTP_CALLBACK_STATUS_FLAG_CERT_CN_INVALID ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'SSL certificate common name(host name field) is incorrect.';
        end;
        // 0x20
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_CERT_DATE_INVALID ) = WINHTTP_CALLBACK_STATUS_FLAG_CERT_DATE_INVALID ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'CSSL certificate date that was received from the server is bad. The certificate is expired.';
        end;
        // 0x80000000
        if ( ( DWORD(lpvStatusInformation) and WINHTTP_CALLBACK_STATUS_FLAG_SECURITY_CHANNEL_ERROR ) = WINHTTP_CALLBACK_STATUS_FLAG_SECURITY_CHANNEL_ERROR ) then
        begin
          LogBuffer := LogBuffer + sLineBreak + 'The application experienced an internal error loading the SSL libraries.';
        end;
      end
      else
      begin
        LogBuffer := 'SECURE_FAILURE (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_SENDING_REQUEST :
    // Sending the information request to the server.
    // The lpvStatusInformation parameter is NULL.
    begin
      LogBuffer := 'SENDING_REQUEST (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE :
    // Upon receiving this, the application can start to receive a response from
    // the server with WinHttpReceiveResponse.
    begin
      REQ_CONTEXT := P_REQ_CONTEXT^;
      LogBuffer := 'SENDREQUEST_COMPLETE (' + IntToStr(dwStatusInformationLength) + ')';
      // Prepare the request handle to receive a response.
      if ( WinHttpReceiveResponse(REQ_CONTEXT.hRequest, Nil) = False ) then
      begin
        Cleanup( REQ_CONTEXT, 'WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE');
      end;
    end;

    WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE :
    // Data was successfully written to the server. The lpvStatusInformation
    // parameter contains a pointer to a DWORD that indicates the number of bytes written.
		// When used by WinHttpWebSocketSend, the lpvStatusInformation parameter
    // contains a pointer to a WINHTTP_WEB_SOCKET_STATUS structure, and the
		// dwStatusInformationLength parameter indicates the size of lpvStatusInformation.
    begin
      if ( lpvStatusInformation <> Nil ) then
      begin
        LogBuffer := 'WRITE_COMPLETE (' + IntToStr(DWORD(lpvStatusInformation)) + ')';
      end
      else
      begin
        LogBuffer := 'WRITE_COMPLETE (' + IntToStr(dwStatusInformationLength) + ')';
      end;
    end;

    WINHTTP_CALLBACK_STATUS_GETPROXYFORURL_COMPLETE :
    // The operation initiated by a call to WinHttpGetProxyForUrlEx is complete.
    // Data is available to be retrieved with WinHttpReadData.
    begin
      LogBuffer := 'GETPROXYFORURL_COMPLETE (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE :
    // The connection was successfully closed via a call to WinHttpWebSocketClose.
    begin
      LogBuffer := 'CLOSE_COMPLETE (' + IntToStr(dwStatusInformationLength) + ')';
    end;

    WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE :
    // The connection was successfully shut down via a call to WinHttpWebSocketShutdown
    begin
      LogBuffer := 'SHUTDOWN_COMPLETE (' + IntToStr(dwStatusInformationLength) + ')';
    end;

  // default
  else
    begin
      LogBuffer :='Unknown/unhandled callback - status ' + IntToStr(dwInternetStatus) + ' given.';
    end;
  end;

  // Add the callback information to the listbox.
  SendMessageW( LogProgressHandle, LB_ADDSTRING, 0, NativeUInt(PWideChar(LogBuffer)));

end;


end.
