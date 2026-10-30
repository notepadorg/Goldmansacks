USE [Point32HealthAuditClaims]
GO
/****** Object: StoredProcedure [dbo].[ADE_AuditSubmission_Outbound]  Script Date: 28/10/2026 ******/
/*
Developed By     : Mukeshwar R M
Developed At     : Chennai
Development Date : 28/10/2026
Description      : Development Point32 Pareo Auditsubmission
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- EXEC [dbo].[ADE_AuditSubmission_Outbound] 128, '1,101,202,303,404,505,606', 215, 0

CREATE OR ALTER PROC [dbo].[ADE_AuditSubmission_Outbound]
(
 @ClientId INT,
 @FlowID VARCHAR(100),
 @ClientFileConfigurationId INT,
 @Debug BIT = 0
)
AS
BEGIN
 SET NOCOUNT ON

 DECLARE @SQLQuery NVARCHAR(MAX) = N'',
   @WFDB VARCHAR(255) = '',
   @CDB VARCHAR(255) = '',
   @ConfigDB VARCHAR(255) = 'ScioConfig',
   @CanReloadSameClaims BIT = 0,
   @OutboundType VARCHAR(10) = 'AUDIT',
   @ExecutedDate DATETIME = GETDATE()

 SET @SQLQuery = N'
  SELECT
   @CDB = DatabaseName,
   @WFDB = WorkflowDatabaseName
  FROM ' + QUOTENAME(@ConfigDB) + N'.dbo.Client WITH(NOLOCK)
  WHERE Id = @ClientId'

 EXEC sp_executesql
  @SQLQuery,
  N'@ClientId INT, @CDB VARCHAR(255) OUTPUT, @WFDB VARCHAR(255) OUTPUT',
  @ClientId,
  @CDB OUTPUT,
  @WFDB OUTPUT

 SET @SQLQuery = N'
  SELECT
   @CanReloadSameClaims = CanReloadSameClaims
  FROM ' + QUOTENAME(@ConfigDB) + N'.dbo.ClientFileConfiguration WITH(NOLOCK)
  WHERE Id = @ClientFileConfigurationId'

 EXEC sp_executesql
  @SQLQuery,
  N'@ClientFileConfigurationId INT, @CanReloadSameClaims BIT OUTPUT',
  @ClientFileConfigurationId,
  @CanReloadSameClaims OUTPUT

 DROP TABLE IF EXISTS #AuditSubmissionOutbound
 DROP TABLE IF EXISTS #AuditSubmissionOutboundNew
 DROP TABLE IF EXISTS ##AuditSubmissionOutbound
 DROP TABLE IF EXISTS #flowid

 -- FIX: #flowid must exist BEFORE the base query uses it
 CREATE TABLE #flowid
 (
  rn BIGINT PRIMARY KEY,
  ID INT NOT NULL UNIQUE
 )

 SET @SQLQuery = N'
  INSERT INTO #flowid(rn, ID)
  SELECT ROW_NUMBER() OVER (ORDER BY F.Id), F.Id
  FROM ' + QUOTENAME(@WFDB) + N'.dbo.Flow F
  ';

 EXEC (@SQLQuery)

 -- FIX: a temp table created inside EXEC is dropped when the EXEC ends,
 -- so the base query writes into a global temp table and it is copied
 -- into the local one right after.
 SET @SQLQuery = N'
   SELECT 
   CAST(A.Id AS VARCHAR(20)) AS AuditID,
   CL.ClaimLineUID AS MappingClaimLineUID,   -- FIX: renamed (duplicate ClaimLineUID name; UPDATE already uses T.MappingClaimLineUID)
   ISNULL(CAST(CS.ClaimSummaryUID AS VARCHAR(100)), '''') AS ClaimSummaryUID,
   ISNULL(CS.ClaimNumber, '''') AS ClaimNumber,
   '''' AS ClaimLineUID,
   ''Cortex'' AS [Dataset],
   ISNULL(CS.anchorclaimid_cs, CS.ClaimNumber) [Initial Claim Number],
   ISNULL(CS.ClaimNumber, '''') AS [Claim Number],
        ISNULL(CL.Claimlinenumber, '''')  AS [Claim Line Number],
  ISNULL(CS.MemberID, '''') AS [Member ID],
     ISNULL(CONVERT(VARCHAR(10), CS.FirstDateOfService, 101), '''') AS [Date of Service],
        ''EXL'' AS [Vendor Code],
     ISNULL(A.ClientAuditId,'''') AS [Vendor Claim ID],
     ''LIN'' AS [Audit Level],
     ''DM'' AS [Audit Type],
     SC.conceptId AS [Concept ID],
     '''' AS [Project Code],
     CAST(NULL AS DECIMAL(19,2)) AS [Initial_Overpaid_Amount],   -- FIX: missing comma + explicit type
     CAST(NULL AS NVARCHAR(MAX)) AS [Reason Code],
  CAST(NULL AS DECIMAL(19,2)) AS [Audit Amount],
     CAST(NULL AS NVARCHAR(MAX)) AS [Audit Comments],
        CAST(NULL AS NVARCHAR(MAX)) AS [Line Audit Comments],
        ''System'' AS [Auditor],
  ''Postpay'' AS [Payment Timing],
        '''' AS [New DRG],
        '''' AS [Department Code],
        '''' AS [Collections Vendor Code],
        '''' AS [Liability Date],
        '''' AS [Grouping ID],
        '''' AS [Audit Custom Field Name 1],
        '''' AS [Audit Custom Field Value 1],
        '''' AS [Audit Custom Field Name 2],
        '''' AS [Audit Custom Field Value 2],
        '''' AS [Audit Custom Field Name 3],
        '''' AS [Audit Custom Field Value 3],
        '''' AS [Audit Custom Field Name 4],
        '''' AS [Audit Custom Field Value 4],
        '''' AS [Audit Custom Field Name 5],
        '''' AS [Audit Custom Field Value 5],
        '''' AS [Audit Custom Field Name 6],
        '''' AS [Audit Custom Field Value 6],
        '''' AS [Audit Custom Field Name 7],
        '''' AS [Audit Custom Field Value 7],
        '''' AS [Audit Custom Field Name 8],
        '''' AS [Audit Custom Field Value 8],
        '''' AS [Audit Custom Field Name 9],
        '''' AS [Audit Custom Field Value 9],
        '''' AS [Audit Custom Field Name 10],
        '''' AS [Audit Custom Field Value 10],
        CASE
            WHEN CS.ClaimType_cs = ''P'' THEN ''Professional''
            WHEN CS.ClaimType_cs = ''F'' THEN ''Institutional''
            ELSE ISNULL(CS.ClaimType_cs, '''')
            END AS [Claim Type],
        '''' AS [Claim Received Date],
  ISNULL(CONVERT(VARCHAR(10), CS.PaidDate, 101), '''') AS [Claim Paid Date],
  ISNULL(CS.SCIOLOB, '''') AS [Line of Business],
  '''' AS [Product Line],
  '''' AS [Adjustment Reason Code],
  '''' AS [Last Date of Service],

  CAST(ISNULL(CS.TotalChargedAmount,0) as DECIMAL(19,2))  AS [Claim Total Billed Amount],
  CAST(ISNULL(CS.TotalallowedchargedAmount,0) as DECIMAL(19,2))  AS [Claim Total Allowed Amount],
  CAST(ISNULL(CS.TotalPaidAmount,0) as DECIMAL(19,2))  AS [Claim Total Paid Amount],
  CAST(ISNULL(CL.allowedchargedamount,0) as DECIMAL(19,2)) AS [Claim Line Allowed Amount],
  CAST(ISNULL(CL.paidamount,0) as DECIMAL(19,2)) AS [Claim Line Paid Amount],
  '''' AS [Network Indicator],
        ISNULL(CS.PatientAccountnumber, ''0000000'') AS [Patient Account Number],
        ISNULL(CS.MemberLastName, '''') AS [Member Last Name],
  ISNULL(CS.MemberFirstName, '''') AS [Member First Name],
  ISNULL(CONVERT(VARCHAR(10), CS.memberdateofbirth_cs, 101), '''') AS [Member Date of Birth],
        '''' AS [Group ID],
        '''' AS [Group Name],
      CONCAT(  COALESCE(CS.billingprovidernpi, CS.RenderingProviderNPI), ''_'',  CS.ProviderTaxid, ''_'',  CS.ProviderUID) AS [Billing Provider Number],
  ISNULL(CS.billingprovidernpi, CS.RenderingProviderNPI) AS [Billing Provider NPI],
         ISNULL(CS.ProviderTaxid, '''') AS [Billing Provider TIN],
        ISNULL(CS.Providerorganizationname, '''') AS [Billing Provider Name],
        '''' AS [Billing Provider Address1],
        '''' AS [Billing Provider Address2],
        '''' AS [Billing Provider City],
        '''' AS [Billing Provider State],
        '''' AS [Billing Provider Zip],

        CASE
    WHEN CS.Providerassignedid IS NOT NULL
        THEN CS.Providerassignedid
    ELSE
        CONCAT(
            COALESCE(CS.billingprovidernpi, CS.RenderingProviderNPI),
            ''_'',
            CS.ProviderTaxid,
            ''_'',
            CS.ProviderUID
        )
END AS [Rendering Provider Number],
ISNULL(CS.RenderingProviderNPI, CS.billingprovidernpi) AS [Rendering Provider NPI],
        ISNULL(CS.ProviderTaxid, '''') AS [Rendering Provider TIN],
        ISNULL(CS.Providerorganizationname, '''') AS [Rendering Provider Name],

        '''' AS [Claim Custom Field Name 1],
        '''' AS [Claim Custom Field Value 1],
        '''' AS [Claim Custom Field Name 2],
        '''' AS [Claim Custom Field Value 2],
        '''' AS [Claim Custom Field Name 3],
        '''' AS [Claim Custom Field Value 3],
        '''' AS [Claim Custom Field Name 4],
        '''' AS [Claim Custom Field Value 4],
        '''' AS [Claim Custom Field Name 5],
        '''' AS [Claim Custom Field Value 5],
        '''' AS [Claim Custom Field Name 6],
        '''' AS [Claim Custom Field Value 6],
        '''' AS [Claim Custom Field Name 7],
        '''' AS [Claim Custom Field Value 7],
        '''' AS [Claim Custom Field Name 8],
        '''' AS [Claim Custom Field Value 8],
        '''' AS [Claim Custom Field Name 9],
        '''' AS [Claim Custom Field Value 9],
        '''' AS [Claim Custom Field Name 10],
        '''' AS [Claim Custom Field Value 10]

    INTO ##AuditSubmissionOutbound
    FROM ' + QUOTENAME(@WFDB) + N'.dbo.Audit A WITH(NOLOCK)
    JOIN ' + QUOTENAME(@CDB) + N'.dbo.ClaimSummary CS WITH(NOLOCK) ON CS.ClaimSummaryUID = A.ClaimSummaryUID
    JOIN ' + QUOTENAME(@WFDB) + N'.dbo.SubStatus S WITH(NOLOCK) ON S.Id = A.SubStatus_Id
    JOIN ' + QUOTENAME(@WFDB) + N'.dbo.Flow F WITH(NOLOCK) ON F.Id = A.Flow_Id
    JOIN ' + QUOTENAME(@CDB) + N'.dbo.SelectionReasonConceptMap SC WITH(NOLOCK) ON SC.selectionPattern=a.selectionreason
    JOIN ' + QUOTENAME(@CDB) + N'.dbo.claimline CL WITH(NOLOCK) ON CL.ClaimSummaryUID = CS.ClaimSummaryUID
    WHERE a.substatus_Id IN (63)
    AND A.Flow_Id IN (SELECT ID FROM #flowid)
    ';

 EXEC (@SQLQuery)

 SELECT * INTO #AuditSubmissionOutbound FROM ##AuditSubmissionOutbound
 DROP TABLE IF EXISTS ##AuditSubmissionOutbound

 DECLARE @Index INT = 1,
   @FlowCount INT = (SELECT COUNT(*) FROM #flowid),
   @CurrentFlowId INT,
   @Columns NVARCHAR(MAX),
   @Condition NVARCHAR(MAX),
   @UpdateSQL NVARCHAR(MAX),
   @MappingCount INT

 WHILE @Index <= @FlowCount
 BEGIN
  SELECT @CurrentFlowId = ID FROM #flowid WHERE rn = @Index

  -- FIX: reset, otherwise a flow with no mapping row reuses the previous flow's values
  SELECT @Columns = NULL, @Condition = NULL

  SET @SQLQuery = N'
    SELECT @Columns = STUFF((
     SELECT N'','' + FieldName + N'' = '' + FieldMapping
     FROM ' + QUOTENAME(@WFDB) + N'.dbo.ADE_AuditSubmission_FieldMapping
     WHERE FlowId = @CurrentFlowId AND FileExchangeType_Id = 5
       AND FieldName <> N''__RowCondition''
     ORDER BY SortIndex, ID
     FOR XML PATH(''''), TYPE
    ).value(''.'', ''nvarchar(max)''), 1, 1, N'''')

    SELECT @Condition = FieldMapping
    FROM ' + QUOTENAME(@WFDB) + N'.dbo.ADE_AuditSubmission_FieldMapping
    WHERE FlowId = @CurrentFlowId AND FileExchangeType_Id = 5
    AND FieldName = N''__RowCondition''
      ';

  EXEC sp_executesql
                @SQLQuery,
                N'@Columns NVARCHAR(MAX) OUTPUT,
                  @Condition NVARCHAR(MAX) OUTPUT,
                  @CurrentFlowId INT',      -- FIX: was VARCHAR(MAX), now matches the NVARCHAR variables
                @Columns OUTPUT,
                @Condition OUTPUT,
                @CurrentFlowId;

  -- FIX: skip flows with no mapping (NULL would make the whole SQL string NULL)
  IF @Columns IS NOT NULL
  BEGIN
   SET @SQLQuery = N'
    UPDATE T SET  ' + @Columns + N'
    FROM #AuditSubmissionOutbound AS T
    JOIN ' + QUOTENAME(@WFDB) + N'.dbo.audit AS a ON a.id = T.AuditID
    JOIN ' + QUOTENAME(@WFDB) + N'.dbo.CustomValues' + CONVERT(NVARCHAR(11), @CurrentFlowId) + N' AS CV
      ON CV.ClaimLineUid = T.MappingClaimLineUID     -- FIX: removed dangling "and a.Id ="
    WHERE (' + ISNULL(@Condition, N'1=1') + N')
    ';

   EXEC (@SQLQuery)
  END

  SET @Index = @Index + 1
 END

 SELECT * INTO #AuditSubmissionOutboundNew FROM #AuditSubmissionOutbound t WHERE t.[Initial_Overpaid_Amount] IS NOT NULL

 /* TRACKING TABLE - commented out (table does not exist yet)
 DECLARE @InsertSQL NVARCHAR(MAX)

  SET @InsertSQL = N'
  INSERT INTO dbo.ADE_AuditSubmission_Outbound_Tracking_new
  (
   ExecutedDate,
   AuditID,
   ClaimSummaryUID,
   ClaimNumber,
   ClaimLineUID,
   Dataset,
   InitialClaimNumber,
   ClaimNumber_2,
   ClaimLineNumber,
   MemberID,
   DateOfService,
   VendorCode,
   VendorClaimID,
   AuditLevel,
   AuditType,
   ConceptID,
   ProjectCode,
   ReasonCode,
   AuditAmount,
   AuditComments,
   LineAuditComments,
   Auditor,
   PaymentTiming,
   ClaimType,
   ClaimPaidDate,
   LineOfBusiness,
   ClaimTotalBilledAmount,
   ClaimTotalAllowedAmount,
   ClaimTotalPaidAmount,
   ClaimLineAllowedAmount,
   ClaimLinePaidAmount,
   PatientAccountNumber,
   MemberLastName,
   MemberFirstName,
   MemberDOB,
   BillingProviderNumber,
   BillingProviderNPI,
   BillingProviderTIN,
   BillingProviderName,
   RenderingProviderNumber,
   RenderingProviderNPI,
   RenderingProviderTIN,
   RenderingProviderName,
   OutboundType
  )
  SELECT
   getdate(),
   AuditID,
   ClaimSummaryUID,
   ClaimNumber,
   ClaimLineUID,
   Dataset,
   [Initial Claim Number],
   [Claim Number],
   [Claim Line Number],
   [Member ID],
   [Date of Service],
   [Vendor Code],
   [Vendor Claim ID],
   [Audit Level],
   [Audit Type],
   [Concept ID],
   [Project Code],
   [Reason Code],
   [Audit Amount],
   [Audit Comments],
   [Line Audit Comments],
   Auditor,
   [Payment Timing],
   [Claim Type],
   [Claim Paid Date],
   [Line of Business],
   [Claim Total Billed Amount],
   [Claim Total Allowed Amount],
   [Claim Total Paid Amount],
   [Claim Line Allowed Amount],
   [Claim Line Paid Amount],
   [Patient Account Number],
   [Member Last Name],
   [Member First Name],
   [Member Date of Birth],
   [Billing Provider Number],
   [Billing Provider NPI],
   [Billing Provider TIN],
   [Billing Provider Name],
   [Rendering Provider Number],
   [Rendering Provider NPI],
   [Rendering Provider TIN],
   [Rendering Provider Name],
   @OutboundType
  FROM #AuditSubmissionOutboundNew
  ';

  EXEC sp_executesql @InsertSQL, N'@OutboundType VARCHAR(10)', @OutboundType
 */

 SELECT *
  FROM #AuditSubmissionOutboundNew
 ORDER BY [Claim Number], CAST(AuditID AS BIGINT)

END
