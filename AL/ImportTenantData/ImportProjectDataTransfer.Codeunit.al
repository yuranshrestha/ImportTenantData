codeunit 60321 "Import Project Data Transfer"
{
    TableNo = "Job Queue Entry";
    trigger OnRun()
    var
        ImportProjectData: Record "Import Project Data";
    begin
        ImportProjectData.Get("Record ID to Process");
        ImportProjectData.SetRecFilter();
        ExecuteDataTransfer(ImportProjectData);
    end;

    procedure ExecuteDataTransfer(var ImportProjectData: Record "Import Project Data")
    begin
        StartDataTransfer(ImportProjectData, false);
    end;

    procedure ResumeDataTransfer(var ImportProjectData: Record "Import Project Data")
    begin
        StartDataTransfer(ImportProjectData, true);

    end;

    local procedure StartDataTransfer(var ImportProjectData: Record "Import Project Data"; ResumeTransfer: Boolean)
    var
        StartTime: DateTime;
        Total: Integer;
        Counter: Integer;
    begin
        StartTime := RoundDateTime(CurrentDateTime);
        Window.Open(DialogMsg + '\\@2@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@' + '\\@3@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@');
        with ImportProjectData do begin
            Total := Count();
            SetAutoCalcFields("Table Name");
            FindSet();
            repeat
                Counter += 1;
                Window.Update(1, "Table Name");
                Window.Update(2, Round(Counter / Total * 10000, 1));
                Window.Update(3, 0);
                ExecuteDataTransferForTable(ImportProjectData, ResumeTransfer);
            until Next() = 0;
        end;
        Window.Close();
        Message(DataImportFinished, (RoundDateTime(CurrentDateTime) - StartTime));
    end;

    local procedure ExecuteDataTransferForTable(ImportProjectData: Record "Import Project Data"; ResumeTransfer: Boolean)
    var
        ImportProjectTableMapping: Record "Import Project Table Mapping";
        TemplateRecRef: RecordRef;
        HasTemplateRecRef: Boolean;
    begin
        with ImportProjectTableMapping do begin
            SetRange("Project Table ID", ImportProjectData.ID);
            SetFilter("Destination Table ID", '>%1', 0);
            if FindSet() then
                repeat
                    HasTemplateRecRef := TemplateRecRef.Get("Template Record");
                    CopyData(ImportProjectData, ImportProjectTableMapping, HasTemplateRecRef, TemplateRecRef, ResumeTransfer);
                until Next() = 0;
        end;
    end;

    local procedure CopyData(ImportProjectData: Record "Import Project Data"; ImportProjectTableMapping: Record "Import Project Table Mapping"; HasTemplateRecRef: Boolean; TemplateRecRef: RecordRef; ResumeTransfer: Boolean)
    var
        SrcRowList: XmlNodeList;
        SrcRow: XmlNode;
        DestRecRef: RecordRef;
        Total: Integer;
        Counter: Integer;
        UpdateRow: Boolean;
    begin
        Total := InitializeReferences(ImportProjectData, ImportProjectTableMapping, SrcRowList, DestRecRef);
        if Total = 0 then exit;

        foreach SrcRow in SrcRowList do begin
            Counter += 1;
            if (Counter >= ImportProjectTableMapping."No. of Imported Records") or not ResumeTransfer then begin
                DestRecRef.LockTable(true);
                PopulatePrimaryKey(ImportProjectData.ID, SrcRow, DestRecRef);
                UpdateRow := DestRecRef.Find();
                if not UpdateRow then
                    DestRecRef.Init();
                CopyFields(ImportProjectTableMapping, SrcRow, DestRecRef);
                if HasTemplateRecRef then
                    ApplyTemplateRecord(TemplateRecRef, DestRecRef);
                if UpdateRow then begin
                    OnBeforeModify(ImportProjectTableMapping, SrcRow, DestRecRef);
                    DestRecRef.Modify();
                end else
                    if ImportProjectData."Missing Record Handling" = ImportProjectData."Missing Record Handling"::Create then begin
                        OnBeforeInsert(ImportProjectTableMapping, SrcRow, DestRecRef);
                        DestRecRef.Insert();
                    end;

                UpdateImportedRecords(ImportProjectData, ImportProjectTableMapping, Counter, Total);
            end;

            if Counter MOD 100 = 0 then
                Window.Update(3, Round(Counter / Total * 10000, 1));
        end;
        ImportProjectTableMapping.Modify();
    end;

    local procedure UpdateImportedRecords(ImportProjectData: Record "Import Project Data"; var ImportProjectTableMapping: Record "Import Project Table Mapping"; Counter: Integer; Total: Integer)
    begin
        ImportProjectTableMapping."No. of Records" := Total;
        ImportProjectTableMapping."No. of Imported Records" := Counter;

        case ImportProjectData."Commit Interval" of
            ImportProjectData."Commit Interval"::"Every record":
                begin
                    ImportProjectTableMapping.Modify();
                    Commit();
                end;

            ImportProjectData."Commit Interval"::"Every 100 records":
                if Counter MOD 100 = 0 then begin
                    ImportProjectTableMapping.Modify();
                    Commit();
                end;
            ImportProjectData."Commit Interval"::"Every 1.000 records":
                if Counter MOD 1000 = 0 then begin
                    ImportProjectTableMapping.Modify();
                    Commit();
                end;
            ImportProjectData."Commit Interval"::"Every 10.000 records":
                if Counter MOD 10000 = 0 then begin
                    ImportProjectTableMapping.Modify();
                    Commit();
                end;
        end;
        ImportProjectTableMapping.LockTable(true);
    end;

    local procedure InitializeReferences(ImportProjectData: Record "Import Project Data"; ImportProjectTableMapping: Record "Import Project Table Mapping"; var SrcRowList: XmlNodeList; var DestRecRef: RecordRef) RowCount: Integer
    var
        Xml: XmlDocument;
        NodeMgt: Codeunit "Import Project Node Mgt.";
    begin
        ImportProjectData.GetXml(Xml);
        if not Xml.SelectNodes(NodeMgt.GetNodeXPath('Row'), SrcRowList) then exit(0);
        DestRecRef.Open(ImportProjectTableMapping."Destination Table Id");
        RowCount := SrcRowList.Count();
    end;

    local procedure CopyFields(ImportProjectTableMapping: Record "Import Project Table Mapping"; SrcRow: XmlNode; var DestRecRef: RecordRef)
    var
        ImportProjectFieldMapping: Record "Import Project Field Mapping";
        ImportProjectField: Record "Import Project Data Field";
        SrcFldValueAsText: Text;
        DestFldRef: FieldRef;
    begin
        FilterFields(ImportProjectTableMapping, ImportProjectFieldMapping);
        with ImportProjectFieldMapping do
            if FindSet() then
                repeat
                    if not GetIsPrimaryKeyField("Destination Field ID") then begin
                        ImportProjectField.Get("Project Table ID", "Project Field ID");
                        SrcFldValueAsText := ImportProjectField.GetFieldValueAsText(SrcRow);
                        DestFldRef := DestRecRef.Field("Destination Field ID");
                        CopyValue(ImportProjectField, "Destination Table Id", SrcFldValueAsText, DestFldRef);
                    end;
                until Next() = 0;
    end;

    local procedure ApplyTemplateRecord(TemplateRecRef: RecordRef; var DestRecRef: RecordRef)
    var
        TempBlob: Record TempBlob;
        CleanRecRef: RecordRef;
        CleanFldRef: FieldRef;
        TemplateFldRef: FieldRef;
        DstFldRef: FieldRef;
        FieldIndex: Integer;
    begin
        CleanRecRef.Open(DestRecRef.Number);
        CleanRecRef.Init();
        for FieldIndex := 1 to CleanRecRef.FieldCount do begin
            CleanFldRef := CleanRecRef.FieldIndex(FieldIndex);
            if (CleanFldRef.Class = FieldClass::Normal) and
                CleanFldRef.Active and not
                (CleanFldRef.Type IN [FieldType::Blob, FieldType::Media, FieldType::MediaSet])
            then begin
                TemplateFldRef := TemplateRecRef.FieldIndex(FieldIndex);
                DstFldRef := DestRecRef.FieldIndex(FieldIndex);
                if format(DstFldRef.Value()) = format(CleanFldRef.Value()) then
                    DstFldRef.Value(TemplateFldRef.Value());
            end;
        end;
    end;

    local procedure FilterFields(ImportProjectTableMapping: Record "Import Project Table Mapping"; var ImportProjectFieldMapping: Record "Import Project Field Mapping")
    begin
        ImportProjectFieldMapping.SetRange("Project Table ID", ImportProjectTableMapping."Project Table ID");
        ImportProjectFieldMapping.SetRange("Destination Table ID", ImportProjectTableMapping."Destination Table ID");
        ImportProjectFieldMapping.SetFilter("Destination Field ID", '>%1', 0);
    end;

    local procedure PopulatePrimaryKey(ProjectTableId: Guid; SrcRow: XmlNode; var DestRecRef: RecordRef)
    var
        ImportProjectField: Record "Import Project Data Field";
        DestFldRef: FieldRef;
        PrimaryKeyRef: KeyRef;
        FieldIndex: Integer;
    begin
        PrimaryKeyRef := DestRecRef.KeyIndex(1);
        for FieldIndex := 1 to PrimaryKeyRef.FieldCount() do begin
            DestFldRef := PrimaryKeyRef.FieldIndex(FieldIndex);
            if ImportProjectField.Get(ProjectTableId, DestFldRef.Number()) then
                CopyValue(ImportProjectField, DestRecRef.Number(), ImportProjectField.GetFieldValueAsText(SrcRow), DestFldRef);
        end;
    end;

    local procedure CopyValue(ImportProjectField: Record "Import Project Data Field"; DestinationTableId: Integer; SrcFldValueAsText: Text; var DestFldRef: FieldRef)
    var
        ImportProjectFieldMapping: Record "Import Project Field Mapping";
        ImportProjectDataBuffer: Record "Import Project Data Buffer" temporary;
        DataBufferFldRef: FieldRef;
        Handled: Boolean;
    begin
        OnBeforeCopyValue(ImportProjectFieldMapping, SrcFldValueAsText, DestFldRef, Handled);
        if Handled then exit;
        ImportProjectDataBuffer.Insert(true);
        with ImportProjectFieldMapping do begin
            Get(ImportProjectField.ID, ImportProjectField."Field ID", DestinationTableId);
            if GetWarning() <> '' then exit;
            if "Transformation Rule" <> '' then begin
                ApplyTransformationRule("Transformation Rule", SrcFldValueAsText);
                EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DestFldRef);
            end else
                if format(DestFldRef.Type) = ImportProjectField."Data Type" then
                    EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DestFldRef)
                else
                    case true of
                        (format(DestFldRef.Type) in ['Text', 'Code']) and (ImportProjectField."Data Type" in ['Text', 'Code', 'Guid']):
                            EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DestFldRef);
                        (format(DestFldRef.Type) in ['Integer', 'Option', 'Enum']) and (ImportProjectField."Data Type" in ['Integer', 'Option']):
                            EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DestFldRef);
                        (format(DestFldRef.Type) in ['Date']) and (ImportProjectField."Data Type" in ['DateTime']):
                            begin
                                ImportProjectDataBuffer.GetFieldAsFieldRef(ImportProjectDataBuffer.FieldNo("Date Time Type"), DataBufferFldRef);
                                EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DataBufferFldRef);
                                ImportProjectDataBuffer."Date Time Type" := DataBufferFldRef.Value();
                                DestFldRef.Value(DT2Date(ImportProjectDataBuffer."Date Time Type"));
                            end;
                        (format(DestFldRef.Type) in ['Time']) and (ImportProjectField."Data Type" in ['DateTime']):
                            begin
                                ImportProjectDataBuffer.GetFieldAsFieldRef(ImportProjectDataBuffer.FieldNo("Date Time Type"), DataBufferFldRef);
                                EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DataBufferFldRef);
                                ImportProjectDataBuffer."Date Time Type" := DataBufferFldRef.Value();
                                DestFldRef.Value(DT2Time(ImportProjectDataBuffer."Date Time Type"));
                            end;
                        (format(DestFldRef.Type) in ['DateTime']) and (ImportProjectField."Data Type" in ['Date']):
                            begin
                                ImportProjectDataBuffer.GetFieldAsFieldRef(ImportProjectDataBuffer.FieldNo("Date Type"), DataBufferFldRef);
                                EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DataBufferFldRef);
                                ImportProjectDataBuffer."Date Type" := DataBufferFldRef.Value();
                                ImportProjectDataBuffer."Time Type" := DT2Time(DestFldRef.Value());
                                DestFldRef.Value(CreateDateTime(ImportProjectDataBuffer."Date Type", ImportProjectDataBuffer."Time Type"));
                            end;
                        (format(DestFldRef.Type) in ['DateTime']) and (ImportProjectField."Data Type" in ['Time']):
                            begin
                                ImportProjectDataBuffer.GetFieldAsFieldRef(ImportProjectDataBuffer.FieldNo("Time Type"), DataBufferFldRef);
                                EvaluateFieldValue(ImportProjectField."Data Type", SrcFldValueAsText, DataBufferFldRef);
                                ImportProjectDataBuffer."Time Type" := DataBufferFldRef.Value();
                                ImportProjectDataBuffer."Date Type" := DT2Date(DestFldRef.Value());
                                DestFldRef.Value(CreateDateTime(ImportProjectDataBuffer."Date Type", ImportProjectDataBuffer."Time Type"));
                            end;

                        else
                            error(FieldTypeTransformationNotSupportedErr, DestFldRef.Type, ImportProjectField."Data Type");
                    end;
        end;
        OnAfterCopyValue(ImportProjectFieldMapping, SrcFldValueAsText, DestFldRef);
    end;

    local procedure ApplyTransformationRule(TransformationRuleCode: Code[20]; var FieldValue: Text)
    var
        TransformationRule: Record "Transformation Rule";
    begin
        TransformationRule.Get(TransformationRuleCode);
        FieldValue := TransformationRule.TransformText(FieldValue);
    end;

    local procedure EvaluateFieldValue(ImportFieldType: Text; FieldValue: Text; var DestFldRef: FieldRef)
    var
        TempBlob: Record TempBlob;
        DateformulaType: DateFormula;
        RecordIDType: RecordID;
        BooleanType: Boolean;
        DecimalType: Decimal;
        IntegerType: Integer;
        DateType: Date;
        DateTimeType: DateTime;
        OptionType: Option;
        BigIntegerType: BigInteger;
        TimeType: Time;
        GuidType: Guid;
        ClosingDate: Boolean;
    begin
        case ImportFieldType of
            format(FieldType::DateTime):
                if FieldValue = '1753-01-01T00:00:00' then
                    FieldValue := '';
            format(FieldType::Date):
                if FieldValue = '1753-01-01T00:00:00' then
                    FieldValue := ''
                else begin
                    FieldValue := CopyStr(FieldValue, 1, 10);
                    ClosingDate := CopyStr(FieldValue, 12, 8) = '23:59:59';
                end;
            format(FieldType::Time):
                if FieldValue = '1753-01-01T00:00:00' then
                    FieldValue := ''
                else
                    FieldValue := CopyStr(FieldValue, 12);
        end;

        case DestFldRef.Type() of
            FieldType::Text:
                DestFldRef.Value := FieldValue;
            FieldType::DateTime:
                begin
                    if FieldValue <> '' then
                        Evaluate(DateTimeType, FieldValue, 9)
                    else
                        DateTimeType := 0DT;
                    DestFldRef.Value := DateTimeType;
                end;
            FieldType::DATE:
                begin
                    if FieldValue <> '' then begin
                        Evaluate(DateType, FieldValue, 9);
                        if ClosingDate then
                            DestFldRef.Value := ClosingDate(DateType)
                        else
                            DestFldRef.Value := NormalDate(DateType);
                    end else
                        DestFldRef.Value := 0D;
                end;
            FieldType::TIME:
                begin
                    if FieldValue <> '' then
                        Evaluate(TimeType, FieldValue, 9)
                    else
                        TimeType := 0T;
                    DestFldRef.Value := TimeType;
                end;
            FieldType::DATEFORMULA:
                begin
                    if FieldValue <> '' then
                        Evaluate(DateformulaType, FieldValue, 9)
                    else
                        Clear(DateformulaType);
                    DestFldRef.Value := DateformulaType;
                end;
            FieldType::DECIMAL:
                begin
                    if FieldValue <> '' then
                        Evaluate(DecimalType, FieldValue, 9)
                    else
                        DecimalType := 0;
                    DestFldRef.Value := DecimalType;
                end;
            FieldType::BOOLEAN:
                begin
                    if FieldValue <> '' then
                        Evaluate(BooleanType, FieldValue, 9)
                    else
                        BooleanType := false;
                    DestFldRef.Value := BooleanType;
                end;
            FieldType::CODE:
                DestFldRef.Value := FieldValue;
            FieldType::OPTION:
                begin
                    if FieldValue <> '' then
                        Evaluate(OptionType, FieldValue, 9)
                    else
                        OptionType := 0;
                    DestFldRef.Value := OptionType;
                end;
            FieldType::INTEGER:
                begin
                    if FieldValue <> '' then
                        Evaluate(IntegerType, FieldValue, 9)
                    else
                        IntegerType := 0;
                    DestFldRef.Value := IntegerType;
                end;
            FieldType::BIGINTEGER:
                begin
                    if FieldValue <> '' then
                        Evaluate(BigIntegerType, FieldValue, 9)
                    else
                        IntegerType := 0;
                    DestFldRef.Value := BigIntegerType;
                end;
            FieldType::BLOB:
                begin
                    TempBlob.WriteAsText(FieldValue, TextEncoding::Windows);
                    DestFldRef.Value(TempBlob.Blob);
                end;
            FieldType::GUID:
                begin
                    if FieldValue <> '' then
                        Evaluate(GuidType, FieldValue, 9)
                    else
                        Clear(GuidType);
                    DestFldRef.Value := GuidType;
                end;
            FieldType::RECORDID:
                begin
                    if FieldValue <> '' then
                        Evaluate(RecordIDType, FieldValue, 9)
                    else
                        Clear(RecordIDType);
                    DestFldRef.Value := RecordIDType;
                end;
            else
                Error(FieldTypeNotSupportedErr, UpperCase(Format(DestFldRef.Type())));

        end;
    end;

    [IntegrationEvent(false, false)]
    local procedure OnBeforeModify(ImportProjectTableMapping: Record "Import Project Table Mapping"; SrcRec: XmlNode; var DestRecRef: RecordRef)
    begin

    end;

    [IntegrationEvent(false, false)]
    local procedure OnBeforeInsert(ImportProjectTableMapping: Record "Import Project Table Mapping"; SrcRec: XmlNode; var DestRecRef: RecordRef)
    begin

    end;

    [IntegrationEvent(false, false)]
    local procedure OnBeforeCopyValue(ImportProjectFieldMapping: Record "Import Project Field Mapping"; SrcFldValueAsText: Text; var DestFldRef: FieldRef; var Handled: Boolean)
    begin

    end;

    [IntegrationEvent(false, false)]
    local procedure OnAfterCopyValue(ImportProjectFieldMapping: Record "Import Project Field Mapping"; SrcFldValueAsText: Text; var DestFldRef: FieldRef)
    begin

    end;


    var
        DialogMsg: Label 'Executing Data Import for table: #1##############################';
        FieldTypeNotSupportedErr: Label 'Field Type %1 not supported!';
        FieldTypeTransformationNotSupportedErr: Label 'Field value transformation from type %1 to %2 not supported!';
        DataImportFinished: Label 'Data Import Completed. Duration %1';
        Window: Dialog;

}