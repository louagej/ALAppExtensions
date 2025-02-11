namespace Microsoft.Integration.Shopify;

codeunit 30228 "Shpfy Refunds API"
{
    var
        CommunicationMgt: Codeunit "Shpfy Communication Mgt.";
        JsonHelper: Codeunit "Shpfy Json Helper";
        RefundEnumConvertor: Codeunit "Shpfy Refund Enum Convertor";
        RefundCantCreateCreditMemoErr: Label 'The refund imported from Shopify can''t be used to create a credit memo. Only refunds for paid items can be used to create credit memos.';

    internal procedure GetRefunds(JRefunds: JsonArray)
    var
        JRefund: JsonToken;
    begin
        foreach JRefund in JRefunds do
            GetRefund(JsonHelper.GetValueAsBigInteger(JRefund, 'legacyResourceId'), JsonHelper.GetValueAsDateTime(JRefund, 'updatedAt'));
    end;

    internal procedure VerifyRefundCanCreateCreditMemo(RefundId: BigInteger)
    var
        RefundLine: Record "Shpfy Refund Line";
    begin
        RefundLine.SetRange("Refund Id", RefundId);
        RefundLine.SetRange("Can Create Credit Memo", false);
        if not RefundLine.IsEmpty() then
            Error(RefundCantCreateCreditMemoErr);
    end;

    local procedure GetRefund(RefundId: BigInteger; UpdatedAt: DateTime)
    var
        RefundHeader: Record "Shpfy Refund Header";
        GraphQLType: Enum "Shpfy GraphQL Type";
        Parameters: Dictionary of [text, Text];
        JResponse: JsonToken;
        JLines: JsonArray;
        JLine: JsonToken;
    begin
        GetRefundHeader(RefundId, UpdatedAt, RefundHeader);
        Parameters.Add('RefundId', Format(RefundId));
        GraphQLType := "Shpfy GraphQL Type"::GetRefundLines;
        repeat
            JResponse := CommunicationMgt.ExecuteGraphQL(GraphQLType, Parameters);
            GraphQLType := "Shpfy GraphQL Type"::GetNextRefundLines;
            JLines := JsonHelper.GetJsonArray(JResponse, 'data.refund.refundLineItems.nodes');
            if Parameters.ContainsKey('After') then
                Parameters.Set('After', JsonHelper.GetValueAsText(JResponse, 'data.refund.refundLineItems.pageInfo.endCursor'))
            else
                Parameters.Add('After', JsonHelper.GetValueAsText(JResponse, 'data.refund.refundLineItems.pageInfo.endCursor'));
            foreach JLine in JLines do
                FillInRefundLine(RefundId, JLine.AsObject(), RefundHeader."Total Refunded Amount" > 0);
        until not JsonHelper.GetValueAsBoolean(JResponse, 'data.refund.refundLineItems.pageInfo.hasNextPage');
    end;

    local procedure GetRefundHeader(RefundId: BigInteger; UpdatedAt: DateTime; var RefundHeader: Record "Shpfy Refund Header")
    var
        DataCapture: Record "Shpfy Data Capture";
        RefundHeaderRecordRef: RecordRef;
        IsNew: Boolean;
        Parameters: Dictionary of [Text, Text];
        JRefund: JsonObject;
        JResponse: JsonToken;
    begin
        if not RefundHeader.Get(RefundId) then
            IsNew := true
        else
            if RefundHeader."Updated At" >= UpdatedAt then
                exit;
        Parameters.Add('RefundId', Format(RefundId));
        JResponse := CommunicationMgt.ExecuteGraphQL("Shpfy GraphQL Type"::GetRefundHeader, Parameters);
        JRefund := JsonHelper.GetJsonObject(JResponse, 'data.refund');
        if IsNew then begin
            Clear(RefundHeader);
            RefundHeader."Refund Id" := RefundId;
            RefundHeader."Order Id" := JsonHelper.GetValueAsBigInteger(JRefund, 'order.legacyResourceId');
            RefundHeader."Return Id" := CommunicationMgt.GetIdOfGId(JsonHelper.GetValueAsText(JRefund, 'return.id'));
            RefundHeader."Created At" := JsonHelper.GetValueAsDateTime(JRefund, 'createdAt');
            RefundHeader."Shop Code" := CommunicationMgt.GetShopRecord().Code;
            RefundHeader.Insert();
        end;
        RefundHeader.SetNote(JsonHelper.GetValueAsText(JRefund, 'note'));
        RefundHeaderRecordRef.GetTable(RefundHeader);
        JsonHelper.GetValueIntoField(JRefund, 'updatedAt', RefundHeaderRecordRef, RefundHeader.FieldNo("Updated At"));
        JsonHelper.GetValueIntoField(JRefund, 'totalRefundedSet.shopMoney.amount', RefundHeaderRecordRef, RefundHeader.FieldNo("Total Refunded Amount"));
        JsonHelper.GetValueIntoField(JRefund, 'totalRefundedSet.presentmentMoney.amount', RefundHeaderRecordRef, RefundHeader.FieldNo("Pres. Tot. Refunded Amount"));
        RefundHeaderRecordRef.Modify();
        RefundHeaderRecordRef.SetTable(RefundHeader);
        RefundHeaderRecordRef.Close();
        DataCapture.Add(Database::"Shpfy Refund Header", RefundHeader.SystemId, JResponse);
    end;

    local procedure FillInRefundLine(RefundId: BigInteger; JLine: JsonObject; NonZeroRefund: Boolean)
    var
        DataCapture: Record "Shpfy Data Capture";
        RefundLine: Record "Shpfy Refund Line";
        RefundLineRecordRef: RecordRef;
        Id: BigInteger;
    begin
        Id := CommunicationMgt.GetIdOfGId(JsonHelper.GetValueAsText(JLine, 'lineItem.id'));
        if not RefundLine.Get(RefundId, Id) then begin
            RefundLine."Refund Line Id" := Id;
            RefundLine."Refund Id" := RefundId;
            RefundLine."Order Line Id" := Id;
            RefundLine.Insert();
        end;
        RefundLine."Restock Type" := RefundEnumConvertor.ConvertToReStockType(JsonHelper.GetValueAsText(JLine, 'restockType'));
        RefundLineRecordRef.GetTable(RefundLine);
        JsonHelper.GetValueIntoField(JLine, 'quantity', RefundLineRecordRef, RefundLine.FieldNo(Quantity));
        JsonHelper.GetValueIntoField(JLine, 'restocked', RefundLineRecordRef, RefundLine.FieldNo(Restocked));
        JsonHelper.GetValueIntoField(JLine, 'priceSet.shopMoney.amount', RefundLineRecordRef, RefundLine.FieldNo(Amount));
        JsonHelper.GetValueIntoField(JLine, 'priceSet.presentmentMoney.amount', RefundLineRecordRef, RefundLine.FieldNo("Presentment Amount"));
        JsonHelper.GetValueIntoField(JLine, 'subtotalSet.shopMoney.amount', RefundLineRecordRef, RefundLine.FieldNo("Subtotal Amount"));
        JsonHelper.GetValueIntoField(JLine, 'subtotalSet.presentmentMoney.amount', RefundLineRecordRef, RefundLine.FieldNo("Presentment Subtotal Amount"));
        JsonHelper.GetValueIntoField(JLine, 'totalTaxSet.shopMoney.amount', RefundLineRecordRef, RefundLine.FieldNo("Total Tax Amount"));
        JsonHelper.GetValueIntoField(JLine, 'totalTaxSet.presentmentMoney.amount', RefundLineRecordRef, RefundLine.FieldNo("Presentment Total Tax Amount"));
        RefundLineRecordRef.SetTable(RefundLine);
        RefundLine."Can Create Credit Memo" := CanRefundCreateCreditMemo(RefundLine, NonZeroRefund);
        RefundLine.Modify();
        RefundLineRecordRef.Close();
        DataCapture.Add(Database::"Shpfy Refund Line", RefundLine.SystemId, JLine);
    end;

    local procedure CanRefundCreateCreditMemo(RefundLine: Record "Shpfy Refund Line"; NonZeroRefund: Boolean): Boolean
    begin
        case RefundLine."Restock Type" of
            RefundLine."Restock Type"::Cancel:
                exit(false);
            RefundLine."Restock Type"::Return,
            RefundLine."Restock Type"::"Legacy Restock":
                exit(true);
            RefundLine."Restock Type"::"No Restock":
                exit(NonZeroRefund);
        end;
    end;
}