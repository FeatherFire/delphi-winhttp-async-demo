# delphi-winhttp-async-demo
This is a Delphi version of the asynchronous WinHttp API example
at: https://github.com/pierrecoll/winhttpasyncdemo

The reference c++ code (13 Jan 2023 version) is shown in the project file:
WinHttpAsyncDemo.txt and any line number references in comments in the Unit1.pas
file refer to that c++ code.

For a discussion of the c++ example, refer to "Asynchronous Completion in WinHTTP",
at https://learn.microsoft.com/en-us/previous-versions//aa383138(v=vs.85)?redirectedfrom=MSDN
or [archived version](https://web.archive.org/web/20230708214400/https://learn.microsoft.com/en-us/previous-versions//aa383138%28v=vs.85%29?redirectedfrom=MSDN)

The discussion describes an MSDN sample application to download two resources
simultaneously using the HTTP protocol while showing status information in a
listbox, with a callback function, using asynchronous WinHTTP functions.  Note
that the discussion actually applies to the original version of the c++ code,
and that the 2023 version has some changes (primarily that only a single
resource is downloaded).
