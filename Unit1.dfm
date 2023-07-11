object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'Form1'
  ClientHeight = 698
  ClientWidth = 1032
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnActivate = FormActivate
  OnClose = FormClose
  TextHeight = 15
  object Label1: TLabel
    Left = 10
    Top = 84
    Width = 188
    Height = 15
    Caption = 'API Calls and Callback Notifications'
  end
  object Label2: TLabel
    Left = 10
    Top = 14
    Width = 21
    Height = 15
    Caption = 'URL'
  end
  object Label3: TLabel
    Left = 578
    Top = 84
    Width = 43
    Height = 15
    Caption = 'Headers'
  end
  object Label4: TLabel
    Left = 578
    Top = 259
    Width = 48
    Height = 15
    Caption = 'Resource'
  end
  object ListBoxProgress: TListBox
    Left = 10
    Top = 105
    Width = 536
    Height = 576
    AutoComplete = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ItemHeight = 17
    ParentFont = False
    TabOrder = 0
  end
  object EditURL: TEdit
    Left = 37
    Top = 11
    Width = 399
    Height = 23
    TabOrder = 1
    Text = 'EditURL'
  end
  object BtnExit: TButton
    Left = 895
    Top = 8
    Width = 121
    Height = 31
    Caption = 'Exit'
    TabOrder = 2
    OnClick = BtnExitClick
  end
  object CheckBoxAutoProxyDetect: TCheckBox
    Left = 35
    Top = 47
    Width = 183
    Height = 17
    Caption = 'Automatic Proxy Detection'
    TabOrder = 3
  end
  object CheckBoxForceTLS_1_3: TCheckBox
    Left = 224
    Top = 47
    Width = 97
    Height = 17
    Caption = 'Force TLS 1.3'
    TabOrder = 4
  end
  object BtnSendRequest: TButton
    Left = 578
    Top = 8
    Width = 141
    Height = 31
    Caption = 'Send Request'
    TabOrder = 5
    OnClick = BtnSendRequestClick
  end
  object MemoResource: TMemo
    Left = 578
    Top = 280
    Width = 438
    Height = 401
    ScrollBars = ssBoth
    TabOrder = 6
    WordWrap = False
  end
  object MemoHeaders: TMemo
    Left = 578
    Top = 105
    Width = 438
    Height = 136
    ScrollBars = ssBoth
    TabOrder = 7
  end
end
