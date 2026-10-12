USE [DevotedHealthAuditClaims]
GO
/****** Object:  StoredProcedure [dbo].[ADE_AuditStatusUpdateOutbound]    Script Date: 10/12/2026 1:55:26 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* .
Oppurtunity Amount - Validation
Only track reporting status 
*/
-- EXEC ADE_AuditStatusUpdateOutbound 111, '0',162,1

ALTER PROC [dbo].[ADE_AuditStatusUpdateOutbound] 
(
	@ClientId   int,
	@FlowID Varchar(100),
	@ClientFileConfigurationId int,
	@Debug bit null = 0,
	@AuditIds varchar(max)=NULL
)
AS
BEGIN  
DECLARE @LastExecutedDate Datetime, @IsExecuted BIT,@ID INT,@FileExchangeTypeId INT,@FlowCount INT,@I Int=1

SELECT @FileExchangeTypeId=Id FROM dbo.FileExchangeType WHERE FileExchangeName='AuditStatusUpdate'

SELECT @LastExecutedDate = MAX(CreatedAt) FROM DBo.ClientExportAuditStatus(NOLOCK)

SELECT
	@IsExecuted = CASE WHEN DATEDIFF(DAY, @LastExecutedDate, GETDATE()) >= 1 THEN 0 ELSE 1 END

IF @IsExecuted=0
BEGIN

SET @FlowID = '1,101,202,303,404,505,606,707,808,909,1010,1212,1313,1414'

DROP TABLE IF EXISTS dbo.tmpFlowListstatusfile
DROP TABLE IF EXISTS dbo.#AuditIncremental_Status
DROP TABLE IF EXISTS dbo.#OutBoundResult
DROP TABLE IF EXISTS dbo.#OutboundCandidate
DROP TABLE IF EXISTS dbo.#Outbound_Final
DROP TABLE IF EXISTS dbo.#ADE_AuditPassfile

CREATE Table dbo.tmpFlowListstatusfile(RowNo Int,FlowID int)

INSERT INTO dbo.tmpFlowListstatusfile
	SELECT
		ROW_NUMBER() OVER (ORDER BY Item ASC) AS RowNo
	   ,Item
	FROM dbo.ConvertDelimitedListIntoTable(@FlowID, ',')

SELECT
	@FlowCount = COUNT(1)
FROM dbo.tmpFlowListstatusfile

SELECT @ID = MAX(Id) FROM ScioConfig.dbo.ClientFileProcessDetails (NOLOCK) WHERE ClientFileConfiguration_id=182

SELECT * INTO dbo.#ADE_AuditPassfile FROM dbo.ADE_AuditPassfile WHERE ClientFileProcessDetails_id=@ID AND VENDOR='EXL'

DECLARE @SQLQuery NVARCHAR(MAX)
	   ,@WFDB VARCHAR(255)
	   ,@CDB VARCHAR(255)
	   ,@ConfigDB VARCHAR(255) = 'ScioConfig'

SET @ClientId = 111
SET @WFDB = 'Workflow_DevotedHealth'
SET @CDB = 'DevotedHealthAuditClaims'

CREATE TABLE #AuditIncremental_Status (
	Audit_Id INT
   ,ClientAuditId BIGINT
   ,FlowId INT
   ,ClaimSummaryUID VARCHAR(255)
   ,StandardSubStatus VARCHAR(255)
   ,StandardSubStatusId INT
   ,SubStatusSortOrder INT
   ,[Devoted_Status] VARCHAR(255)
   ,[IsCommentRequired] BIT
   ,[IsOPAmountRequired] BIT
   ,[IsFindingReasonCodeRequired] BIT
   ,ActionDate DATETIME
   ,IsLateInventory BIT
   ,DevotedAuditTransactions_Id INT
   ,[IsFindingFlagRequired] BIT
)

INSERT INTO #AuditIncremental_Status
	SELECT
		AuditId
	   ,ClientAuditId
	   ,FlowId
	   ,ClaimSummaryUID
	   ,D.StandardSubstatus
	   ,D.StandardSubStatusId
	   ,SortOrder
	   ,D.ClientStatus
	   ,D.IsCommentRequired
	   ,D.IsOPAmountRequired
	   ,D.IsFindingReasonCodeRequired
	   ,ActionDate
	   ,IsLateInventory
	   ,D.Id AS DevotedAuditTransactions_Id
	   ,D.IsFindingFlagRequired
	FROM dbo.DevotedAuditTransactions D
	JOIN dbo.StandardSubstatusToClientStatusMapping S (NOLOCK) ON D.StandardSubStatusId=S.StandardSubstatusID AND D.FileExchangeTypeId=S.FileExchangeTypeId 
	--AND S.IsActive=1
	WHERE IsReported = 0
	AND D.FileExchangeTypeId = @FileExchangeTypeId

CREATE TABLE Dbo.#OutBoundResult (
	[AuditId] INT
   ,[ClientAuditId] BIGINT
   ,[FlowId] INT
   ,[ClaimsummaryUID] VARCHAR(100)
   ,[Claimnumber] VARCHAR(255)
   ,[ClaimLineUID] VARCHAR(255)
   ,[StandardSubstatus] VARCHAR(255)
   ,[StandardSubstatusId] INT
   ,[SubstatusOrder] INT
   ,[Devoted_Status] VARCHAR(255)
   ,[IsCommentRequired] BIT
   ,[IsOPAmountRequired] BIT
   ,[IsFindingReasonCodeRequired] BIT
   ,[IsLateInventory] BIT
   ,DevotedAuditTransactions_Id INT
   ,IsFindingFlagRequired BIT
	--- Output Columns ---
   ,[Vendor Code] VARCHAR(255)
   ,[Adjudication Record Locator] VARCHAR(255)
   ,[Vendor Audit ID] BIGINT
   ,[Devoted Audit ID] VARCHAR(255)
   ,[Member Record Locator] VARCHAR(255)
   ,[FDOS] VARCHAR(10)
   ,[Status] VARCHAR(255)
   ,[Level Of Dispute] VARCHAR(255)
   ,[Opportunity Amount] VARCHAR(MAX)
   ,[Finding Reason Code] VARCHAR(MAX)
   ,[Audit Comments] VARCHAR(MAX)
   ,[Action Date] Datetime
   ,[Status Reason Code] VARCHAR(MAX)
   ,[Finding Flag] Varchar(5)
)

INSERT INTO #OutBoundResult
	SELECT
		Info.Audit_Id AS [AuditId]
	   ,Info.ClientAuditId
	   ,Info.[FlowId]
	   ,Info.[ClaimSummaryuID]
	   ,CS.[ClaimNumber]
	   ,NULL AS [ClaimLineUID]
	   ,Info.[StandardSubstatus]
	   ,Info.[StandardSubstatusId]
	   ,Info.[SubstatusSortOrder]
	   ,Info.[Devoted_Status]
	   ,Info.[IsCommentRequired]
	   ,Info.[IsOPAmountRequired]
	   ,Info.[IsFindingReasonCodeRequired]
	   ,Info.IsLateInventory
	   ,DevotedAuditTransactions_Id
	   ,IsFindingFlagRequired
		--- OUTPUT COLUMNS ---
	   ,'EXL' AS [Vendor Code]
	   ,CS.ClaimNumber AS [Adjudication Record Locator]
	   ,Info.ClientAuditId AS [Vendor Audit ID]
	   ,R.[Devoted_Audit_ID] AS [Devoted Audit ID]
	   ,CS.MemberId AS [Member Record Locator]
	   ,CASE
			WHEN Info.flowId <> 202 AND
				CS.StatementFromDate NOT LIKE '%1900%' THEN CONVERT(VARCHAR(10), CS.StatementFromDate, 101)
			WHEN Info.flowId <> 202 THEN CONVERT(VARCHAR(10), CS.FirstDateOfService, 101)
			WHEN Info.flowId = 202 THEN CONVERT(VARCHAR(10), CS.FirstDateOfService, 101)
			ELSE NULL
		END AS [FDOS]
	   ,CASE
			WHEN Info.[Devoted_Status] LIKE '%_LEV_1%' THEN REPLACE(Info.[Devoted_Status], '_LEV_1', '')
			WHEN Info.[Devoted_Status] LIKE '%_LEV_2%' THEN REPLACE(Info.[Devoted_Status], '_LEV_2', '')
			WHEN Info.[Devoted_Status] LIKE '%_LEV_3%' THEN REPLACE(Info.[Devoted_Status], '_LEV_3', '')
			ELSE Info.[Devoted_Status]
		END AS [Status]
	   ,CASE
			WHEN Info.[Devoted_Status] LIKE '%_LEV_1%' THEN '1'
			WHEN Info.[Devoted_Status] LIKE '%_LEV_2%' THEN '2'
			WHEN Info.[Devoted_Status] LIKE '%_LEV_3%' THEN '3'
			ELSE ''
		END AS [Level Of Dispute]
	   ,NULL AS [Opportunity Amount]
	   ,NULL AS [Finding Reason Code]
	   ,NULL AS [Audit Comments]
	   ,Info.[ActionDate] AS [Action Date]
	   ,'' AS [Status Reason Code]
	   ,'' AS [Finding Flag]--New Column
	FROM #AuditIncremental_Status Info
	JOIN (SELECT
			ROW_NUMBER() OVER (PARTITION BY Vendor_Audit_ID ORDER BY Action_Date DESC, Id DESC) Rw
		   ,*
		FROM DBO.ADE_AuditSubmissionResponse A (NOLOCK)
		WHERE A.Vendor_Audit_ID IN (SELECT DISTINCT
				ClientAuditId
			FROM #AuditIncremental_Status)) R
		ON R.Rw = 1
			AND Info.ClientAuditId = R.Vendor_Audit_ID
			AND ISNULL(R.[Devoted_Audit_Id], '') <> ''
	JOIN DBO.CLAIMSUMMARY CS (NOLOCK)
		ON CS.CLAIMSUMMARYUID = Info.CLAIMSUMMARYUID
	WHERE 1 =
	CASE
		WHEN R.Status = 'APPROVED_AUDIT' THEN 1
		ELSE 0
	END

WHILE(@I<=@FlowCount)
BEGIN
	DECLARE @FID INT,@Columns varchar(max)

SELECT
	@FID = FlowID
FROM dbo.tmpFlowListstatusfile
WHERE RowNo = @I

SELECT
	@Columns = STUFF(((SELECT
			CONCAT(',', FieldName, '=', FieldMapping)
		FROM dbo.FileExchangeMapping
		WHERE FlowId = @FID
		AND FileExchangeType_Id = @FileExchangeTypeId
		ORDER BY SortIndex
		FOR XML PATH (''), TYPE)
	.value('./text()[1]', 'varchar(max)')
	), 1, 1, '')

IF (@Columns IS NOT NULL)
BEGIN
SET @SQLQuery = CONCAT('UPDATE T SET ', @Columns, '
						FROM dbo.#OutBoundResult T 
						INNER JOIN ', @WFDB, '.dbo.StandardSubstatusView SS WITH(NOLOCK) ON T.StandardSubstatusId=SS.StandardSubstatusId
						', IIF(@FID = 1414, ' JOIN Claimsummary CS WITH(NOLOCK) ON T.ClaimSummaryuID=CS.ClaimSummaryuID ', ''), '
						INNER JOIN ', @WFDB, '.DBO.CustomValues', @FID, ' CV WITH(NOLOCK) ON T.AuditId = CV.Audit_Id 
						WHERE CV.ClaimLineUID IS NULL')
		--print @SQLQuery
EXEC (@SQLQuery)
END
SET @I = @I + 1
END


/* ============================================================
   NEW: Append line-level denial text to Audit Comments for Flow 404
   ============================================================ */
UPDATE T
SET [Audit Comments] = CONCAT(
        NULLIF(LTRIM(RTRIM(T.[Audit Comments])), ''),
        CASE WHEN NULLIF(LTRIM(RTRIM(T.[Audit Comments])), '') IS NOT NULL THEN ' | ' ELSE '' END,
        x.LetterText)
FROM dbo.#OutBoundResult T
CROSS APPLY (
    SELECT STUFF((
        SELECT ' ,' + CONCAT(
            'Denial Reason code: ', ISNULL(cv.initial_denial_reason_00, 'N/A'),
            ' Code(s) to be denied: ',
                COALESCE(NULLIF(cl.HCPCCode, ''), cl.CPTCode),
            ' Units Denied: ',
                ISNULL(cl.ServiceUnitCount, 0) - ISNULL(cv.Initial_Units_Validated, 0),
            ' Date of Service :',
                CONVERT(VARCHAR(10), cl.FirstDateOfService, 110)
        )
        FROM dbo.ClaimLine cl
        JOIN Workflow_DevotedHealth.dbo.CustomValues404 cv
            ON cv.Audit_ID = T.AuditId
           AND cv.ClaimLineUID = cl.ClaimLineUID
        WHERE cl.ClaimSummaryUID = T.ClaimSummaryUID
          AND cv.Is_Note_Billable = 'No'
          AND NULLIF(LTRIM(RTRIM(cv.Initial_Auditor_Comments)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(cv.Dispute_1_Auditor_Comments)), '') IS NULL
          AND NULLIF(LTRIM(RTRIM(cv.Dispute_2_Auditor_Comments)), '') IS NULL
        ORDER BY cv.initial_denial_reason_00
        FOR XML PATH(''), TYPE
    ).value('.', 'VARCHAR(MAX)'), 1, 2, '') AS LetterText
) x
WHERE T.FlowId = 404
  AND x.LetterText IS NOT NULL;
/* ============================================================ */

;
WITH T
AS
(SELECT
		ROW_NUMBER() OVER (PARTITION BY AuditId ORDER BY [Action Date], SubstatusOrder) UniqueRowNo
	   ,AuditID
	   ,FlowID
	   ,ClientAuditId
	   ,Claimsummaryuid
	   ,Claimnumber
	   ,ClaimLineUID
	   ,[StandardSubstatus]
	   ,[StandardSubstatusId]
	   ,[Devoted_Status]
	   ,[SubstatusOrder]
	   ,[IsCommentRequired]
	   ,[IsOPAmountRequired]
	   ,[IsFindingReasonCodeRequired]
	   ,IsLateInventory
	   ,DevotedAuditTransactions_Id
	   ,IsFindingFlagRequired
		-- OUTPUT COLUMNS ---
	   ,[Vendor Code]
	   ,[Adjudication Record Locator]
	   ,[Vendor Audit ID]
	   ,[Devoted Audit ID]
	   ,[Member Record Locator]
	   ,[FDOS]
	   ,[Status]
	   ,[Level Of Dispute]
	   ,CASE
			WHEN [Status] NOT IN ('COMPLETED_WITHOUT_FINDING', 'COMPLETED_WITH_FINDING_NO_RECOVERY') THEN CAST(TRY_PARSE(REPLACE([Opportunity Amount], NCHAR(0x00A0), '') AS MONEY) AS VARCHAR(50))
		END AS [Opportunity Amount]
	   ,ISNULL([Finding Reason Code], '') AS [Finding Reason Code]
	   ,DBO.fn_CleanAndTrim(ISNULL([Audit Comments], '')) AS [Audit Comments]
	   ,[Action Date] AS [Action Date]
	   ,[Status Reason Code] AS [Status Reason Code]
	   ,[Finding Flag]
	FROM dbo.#OutBoundResult
	WHERE 1 =
	CASE
		WHEN FlowId IN (1, 101, 303, 404, 505, 606, 707, 808, 909, 1010, 1212, 1313, 1414) AND
			AuditId IS NOT NULL AND
			ClaimSummaryuID IS NOT NULL AND
			ClaimNumber IS NOT NULL AND
			ISNULL([Vendor Code], '') <> '' AND
			ISNULL([Adjudication Record Locator], '') <> '' AND
			ISNULL([Vendor Audit ID], '') <> '' AND
			ISNULL([Devoted Audit ID], '') <> '' AND
			ISNULL([Member Record Locator], '') <> '' AND
			ISNULL([FDOS], '') <> '' AND
			ISNULL([Status], '') <> '' AND
			ISNULL([Action Date], '') <> '' AND
			1 =
			CASE
				WHEN ([StandardSubstatus] LIKE '%Reject%' OR
					[StandardSubstatus] LIKE '%Close%' OR
					[StandardSubstatus] LIKE '%Cancel%' OR
					[StandardSubstatus] LIKE '%RFI%' OR
					[StandardSubstatus] LIKE '%HOLD%') AND
					ISNULL([Status Reason Code], '') = '' THEN 0
				ELSE 1
			END THEN 1
		WHEN FlowId = 202 AND
			AuditId IS NOT NULL AND
			ClaimSummaryuID IS NOT NULL AND
			ClaimNumber IS NOT NULL AND
			ISNULL([Vendor Code], '') <> '' AND
			ISNULL([Adjudication Record Locator], '') <> '' AND
			ISNULL([Vendor Audit ID], '') <> '' AND
			ISNULL([Devoted Audit ID], '') <> '' AND
			ISNULL([Member Record Locator], '') <> '' AND
			ISNULL([FDOS], '') <> '' AND
			ISNULL([Status], '') <> '' AND
			ISNULL([Action Date], '') <> '' AND
			[Opportunity Amount] IS NOT NULL AND
			ISNULL([Finding Reason Code], '') <> '' AND
			ISNULL([Audit Comments], '') <> '' AND
			1 =
			CASE
				WHEN ([StandardSubstatus] LIKE '%Reject%' OR
					[StandardSubstatus] LIKE '%Close%' OR
					[StandardSubstatus] LIKE '%Cancel%' OR
					[StandardSubstatus] LIKE '%RFI%' OR
					[StandardSubstatus] LIKE '%HOLD%') AND
					ISNULL([Status Reason Code], '') = '' THEN 0
				ELSE 1
			END THEN 1
		ELSE 0
	END
	GROUP BY AuditID
			,FlowID
			,ClientAuditId
			,Claimsummaryuid
			,Claimnumber
			,ClaimLineUID
			,StandardSubstatus
			,[StandardSubstatusId]
			,[Devoted_Status]
			,[IsCommentRequired]
			,[IsOPAmountRequired]
			,[IsFindingReasonCodeRequired]
			,IsLateInventory
			,DevotedAuditTransactions_Id
			,IsFindingFlagRequired
			,[SubstatusOrder]
			,[Vendor Code]
			,[Adjudication Record Locator]
			,[Vendor Audit ID]
			,[Devoted Audit ID]
			,[Member Record Locator]
			,[FDOS]
			,[Status]
			,[Level Of Dispute]
			,[Opportunity Amount]
			,[Finding Reason Code]
			,[Audit Comments]
			,[Action Date]
			,[Status Reason Code]
			,[Finding Flag])
SELECT
	AuditID
   ,FlowID
   ,ClientAuditId
   ,Claimsummaryuid
   ,Claimnumber
   ,ClaimLineUID
   ,StandardSubstatus
   ,[StandardSubstatusId]
   ,[Devoted_Status]
   ,[IsCommentRequired]
   ,[IsOPAmountRequired]
   ,[IsFindingReasonCodeRequired]
   ,IsLateInventory
   ,DevotedAuditTransactions_Id
   ,IsFindingFlagRequired
   ,[SubstatusOrder]
   ,[Vendor Code]
   ,[Adjudication Record Locator]
   ,[Vendor Audit ID]
   ,[Devoted Audit ID]
   ,[Member Record Locator]
   ,[FDOS]
   ,[Status]
   ,[Level Of Dispute]
   ,[Opportunity Amount]
   ,[Finding Reason Code]
   ,REPLACE([Audit Comments], CHAR(10), '') AS [Audit Comments]
   ,[Action Date]
   ,[Status Reason Code]
   ,[Finding Flag] INTO dbo.#OutboundCandidate
FROM T
WHERE (UniqueRowNo = 1 OR IsLateInventory=1)
ORDER BY [Action Date] ASC, [SubstatusOrder] ASC, AuditID ASC

DROP TABLE IF EXISTS #ValidationData;

SELECT
	O.AuditId
   ,O.ClientAuditId
   ,P.BaselineStatus AS PreviousStatus
   ,O.Devoted_Status AS CurrentStatus
   ,CAST(CASE WHEN IsLateInventory=1 THEN 1
		WHEN P.BaselineStatus IS NULL THEN 0
		WHEN T.FromClientStatus IS NOT NULL THEN 1
		ELSE 0
	END AS BIT) AS IsValid
   ,DevotedAuditTransactions_Id INTO #ValidationData
FROM #OutboundCandidate O
LEFT JOIN dbo.AuditTransitionBaseline P
	ON O.AuditId = P.AuditId
LEFT JOIN dbo.AuditStatusTransition T
	ON T.FromClientStatus = P.BaselineStatus
		AND T.ToClientStatus = O.Devoted_Status
		AND T.FileExchangeTypeId=3
		AND T.IsActive=1;

SELECT
	C.* INTO dbo.#Outbound_Final
FROM #OutboundCandidate C
INNER JOIN #ValidationData V ON V.DevotedAuditTransactions_Id=C.DevotedAuditTransactions_Id
WHERE V.IsValid = 1


DECLARE @BatchNo INT = 0
SELECT
	@BatchNo = ISNULL(MAX(BatchNo), 0) + 1
FROM dbo.AuditStatusTransitionValidation;

IF @Debug=0
BEGIN
INSERT INTO dbo.AuditStatusTransitionValidation (AuditId
, ClientAuditId
, BaselineStatus
, CurrentStatus
, IsValid
, ValidationMessage
, BatchDate
, DevotedAuditTransactions_Id
, BatchNo
, WasExported)
	SELECT
		AuditId
	   ,ClientAuditId
	   ,PreviousStatus
	   ,CurrentStatus
	   ,IsValid
	   ,CASE
			WHEN PreviousStatus IS NULL THEN 'VALID_NO_BASELINE'
			WHEN IsValid = 1 THEN 'VALID'
			ELSE 'TRANSITION_NOT_FOUND'
		END
	   ,GETDATE()
	   ,DevotedAuditTransactions_Id
	   ,@BatchNo
	   ,0
	FROM #ValidationData;
END
ELSE
BEGIN
	TRUNCATE TABLE dbo.AuditStatusTransitionValidation_test;

	INSERT INTO dbo.AuditStatusTransitionValidation_test(AuditId,ClientAuditId,BaselineStatus,CurrentStatus,IsValid,ValidationMessage,BatchDate,
		DevotedAuditTransactions_Id,WasExported)
	SELECT
		AuditId
		,ClientAuditId
		,PreviousStatus
		,CurrentStatus
		,IsValid
		,CASE
			WHEN PreviousStatus IS NULL THEN 'VALID_NO_BASELINE'
			WHEN IsValid = 1 THEN 'VALID'
			ELSE 'TRANSITION_NOT_FOUND'
		END
		,GETDATE()
		,DevotedAuditTransactions_Id
		,0
	FROM #ValidationData;
	SELECT
		AuditId
	   ,ClientAuditId
	   ,PreviousStatus
	   ,CurrentStatus
	   ,IsValid
	   ,CASE
			WHEN PreviousStatus IS NULL THEN 'VALID_NO_BASELINE'
			WHEN IsValid = 1 THEN 'VALID'
			ELSE 'TRANSITION_NOT_FOUND'
		END
	   ,GETDATE()
	   ,DevotedAuditTransactions_Id
	FROM #ValidationData;
END
/*Remove Audits from outbound if Lastest Devoted Status is Cancelled in Pass file -4/13/2026*/
IF @Debug=0
BEGIN
INSERT INTO AuditStatusUpdateException (AuditID, StandardSubstatus, DevotedStatus, LevelOfDispute, ExceptionReason, CreatedDate)
	SELECT
		A.AuditId
	   ,StandardSubstatus
	   ,A.Devoted_Status
	   ,NULL
	   ,'Cancel Status in PassFile'
	   ,GETDATE()
	FROM #Outbound_Final A
	JOIN (SELECT
			A.ClientAuditId
		   ,B.STATUS
		   ,ROW_NUMBER() OVER (PARTITION BY A.ClientAuditId, AUDIT_STATUS_REASON ORDER BY B.STATUS_CHANGED_AT DESC) Rw
		   ,B.STATUS_CHANGED_AT ActionDate
		FROM #Outbound_Final A (NOLOCK)
		JOIN dbo.#ADE_AuditPassfile B (NOLOCK)
			ON A.[Devoted Audit ID] = B.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR
		WHERE ClientFileProcessDetails_id = @ID
		AND VENDOR = 'EXL') C
		ON C.ClientAuditId = A.ClientAuditId
			AND C.Rw = 1
			AND C.Status = 'CANCELED'
END
DELETE O
	FROM #Outbound_Final O
	JOIN (SELECT
			A.ClientAuditId
		   ,B.STATUS
		   ,ROW_NUMBER() OVER (PARTITION BY A.ClientAuditId, AUDIT_STATUS_REASON ORDER BY B.STATUS_CHANGED_AT DESC) Rw
		   ,B.STATUS_CHANGED_AT ActionDate
		FROM #Outbound_Final A (NOLOCK)
		JOIN dbo.#ADE_AuditPassfile B (NOLOCK)
			ON A.[Devoted Audit ID] = B.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR
		WHERE ClientFileProcessDetails_id = @ID
		AND VENDOR = 'EXL') C
		ON C.ClientAuditId = O.ClientAuditId
		AND C.Rw = 1
		AND C.Status = 'CANCELED'

/*Remove RECEIVED_MED_REC from outbound if Lastest Devoted Status is RECEIVED_MED_REC in Pass file -4/13/2026*/
DELETE O
	FROM #Outbound_Final O
	JOIN (SELECT
			A.ClientAuditId
		   ,B.AUDIT_STATUS_REASON
		   ,ROW_NUMBER() OVER (PARTITION BY A.ClientAuditId, AUDIT_STATUS_REASON ORDER BY B.STATUS_CHANGED_AT DESC) Rw
		   ,B.STATUS_CHANGED_AT ActionDate
		FROM #Outbound_Final A (NOLOCK)
		JOIN dbo.#ADE_AuditPassfile B (NOLOCK)
			ON A.[Devoted Audit ID] = B.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR
		WHERE ClientFileProcessDetails_id = @ID
		AND VENDOR = 'EXL') C
		ON C.ClientAuditId = O.ClientAuditId
		AND C.AUDIT_STATUS_REASON = O.status
		AND C.Rw = 1
		AND O.Status = 'RECEIVED_MED_REC'

IF (@Debug=0)
BEGIN
INSERT INTO FileExchangeException (FileExchangeTypeId, ClientAuditId, StandardSubstatusId, ErrorMessage, IsNotifiedToPOD, CreatedAt, DevotedStatus, OpportunityAmount, FindingsReasonCode, AuditorComments, StatusReasonCode
, Program, AuditId, FixStatus, ActionDate)
	SELECT
		@FileExchangeTypeId
	   ,O.ClientAuditId
	   ,O.StandardSubstatusId
	   ,CASE
			WHEN [Finding Flag] = 'Y' AND
				NULLIF(NULLIF([Finding Reason Code], 'NOFINDING '), '') IS NULL THEN 'Invalid Findings Reason Code'
			WHEN [Finding Flag] = 'Y' AND
				NULLIF(TRY_CONVERT(MONEY, NULLIF(REPLACE([Opportunity Amount], NCHAR(0x00A0), ''), '')), 0) IS NULL THEN 'Invalid Opportunity Amount'
			WHEN [Finding Flag] = 'Y' AND
				NULLIF(NULLIF([Audit Comments], '-'), '') IS NULL THEN 'Missing Auditor Comments'
			WHEN ([status] LIKE '%Overturn%') AND
				NULLIF(NULLIF([Status Reason Code], '-'), '') IS NULL THEN 'Missing Overturn Reason Code'
			WHEN ([status] LIKE '%Cancel%') AND
				NULLIF(NULLIF([Status Reason Code], '-'), '') IS NULL THEN 'Missing Cancel Reason Code'
		END
	   ,0
	   ,GETDATE()
	   ,Devoted_Status
	   ,[Opportunity Amount]
	   ,[Finding Reason Code]
	   ,[Audit Comments]
	   ,[Status Reason Code]
	   ,CASE
			WHEN D.flowId IN (1, 101) AND
				A.SelectionReason LIKE '%CVA%' THEN 'CVA'
			WHEN D.flowId IN (1, 101) THEN 'MSDRG'
			WHEN D.flowId = 1212 THEN 'SNF Per Diem'
			ELSE D.AuditProgram
		END
	   ,O.AuditId
	   ,'Open' AS FixStatus
	   ,O.[Action Date]
	FROM #Outbound_Final O
	JOIN Workflow_DevotedHealth.dbo.Audit A (NOLOCK) ON O.ClientAuditId=A.ClientAuditId
	JOIN DH_FlowProgramCodeMapping D (NOLOCK)
		ON O.FlowId = D.FlowId
	WHERE (CASE
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(NULLIF([Finding Reason Code], 'NOFINDING '), '') IS NULL THEN 1
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(TRY_CONVERT(MONEY, NULLIF(REPLACE([Opportunity Amount], NCHAR(0x00A0), ''), '')), 0) IS NULL THEN 1
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(NULLIF([Audit Comments], '-'), '') IS NULL THEN 1
		WHEN ([status] LIKE '%Overturn%' OR
			[status] LIKE '%Cancel%') AND
			NULLIF(NULLIF([Status Reason Code], '-'), '') IS NULL THEN 1
	END) = 1
	AND NOT EXISTS (SELECT
			1
		FROM FileExchangeException F
		WHERE F.ClientAuditId = O.ClientAuditId
		AND F.FixStatus = 'Open'
		AND F.DevotedStatus = O.Devoted_Status)
END

DELETE FROM #Outbound_Final
WHERE (CASE
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(NULLIF([Finding Reason Code], 'NOFINDING '), '') IS NULL THEN 1
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(TRY_CONVERT(MONEY, NULLIF(REPLACE([Opportunity Amount], NCHAR(0x00A0), ''), '')), 0) IS NULL THEN 1
		WHEN [Finding Flag] = 'Y' AND
			NULLIF(NULLIF([Audit Comments], '-'), '') IS NULL THEN 1
		WHEN ([status] LIKE '%Overturn%' OR
			[status] LIKE '%Cancel%') AND
			NULLIF(NULLIF([Status Reason Code], '-'), '') IS NULL THEN 1
	END) = 1

IF @Debug=0
BEGIN
INSERT INTO AuditStatusUpdateException (AuditID, StandardSubstatus, DevotedStatus, LevelOfDispute, ExceptionReason, CreatedDate)
	SELECT
		AuditID
	   ,StandardSubstatus
	   ,[Status]
	   ,NULL
	   ,'Audit Cancelled By Client'
	   ,GETDATE()
	FROM #Outbound_Final T
	WHERE [status] = 'CANCEL'
	AND ISNULL(T.IsLateInventory, 0) <> 1
	AND EXISTS (SELECT
			1
		FROM dbo.ADE_AuditStatusUpdateReponse A
		WHERE A.Devoted_Audit_ID = T.[Devoted Audit ID]
		AND A.Status IN ('CANCELED', 'CANCEL'))
END

DELETE T
	FROM #Outbound_Final T
WHERE [status] = 'CANCEL'
	AND ISNULL(T.IsLateInventory, 0) <> 1
	AND EXISTS (SELECT
			1
		FROM dbo.ADE_AuditStatusUpdateReponse A
		WHERE A.Devoted_Audit_ID = T.[Devoted Audit ID]
		AND A.Status IN ('CANCELED', 'CANCEL'))


IF @Debug=0
BEGIN
INSERT INTO AuditStatusUpdateException (AuditID, StandardSubstatus, DevotedStatus, LevelOfDispute, ExceptionReason, CreatedDate)
	SELECT
		AuditID
	   ,StandardSubstatus
	   ,A.[Status]
	   ,[Level Of Dispute]
	   ,'Received Dispute Pass File'
	   ,GETDATE()
	FROM #Outbound_Final A
	JOIN #ADE_AuditPassfile AP (NOLOCK)
		ON A.[Devoted Audit ID] = AP.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR
	WHERE AP.ClientFileProcessDetails_id = @ID
	AND VENDOR = 'EXL'
	AND A.[Status] = 'RECEIVED_DISPUTE_VENDOR'
	AND AP.AUDIT_STATUS_REASON IN ('RECEIVED_DISPUTE_AFTER_RECOVERY_DEVOTED', 'RECEIVED_DISPUTE_VENDOR', 'RECEIVED_DISPUTE_DEVOTED')
END

DELETE A
	FROM #Outbound_Final A
	JOIN #ADE_AuditPassfile AP (NOLOCK)
		ON A.[Devoted Audit ID] = AP.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR
WHERE AP.ClientFileProcessDetails_id = @ID
	AND VENDOR = 'EXL'
	AND A.[Status] = 'RECEIVED_DISPUTE_VENDOR'
	AND AP.AUDIT_STATUS_REASON IN ('RECEIVED_DISPUTE_AFTER_RECOVERY_DEVOTED', 'RECEIVED_DISPUTE_VENDOR', 'RECEIVED_DISPUTE_DEVOTED')
	AND A.AuditId NOT IN (SELECT
			AuditId
		FROM ReportLateInventory);


DROP TABLE IF EXISTS #tempActionDates
DROP TABLE IF EXISTS #tempActionDatesFinal
DROP TABLE IF EXISTS #tmpUpdatesRequired

CREATE Table dbo.#tempActionDates(
DevotedAuditId varchar(255),
ActionDate Datetime
)
CREATE Table dbo.#tempActionDatesFinal(
DevotedAuditId varchar(255),
ActionDate Datetime
)

INSERT INTO #tempActionDates (DevotedAuditId, ActionDate)
	SELECT
		PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR Devoted_Audit_ID
	   ,STATUS_CHANGED_AT Action_Date
	FROM dbo.#ADE_AuditPassfile A (NOLOCK)
	JOIN #Outbound_Final B
		ON A.PAYMENT_INTEGRITY_AUDIT_RECORD_LOCATOR = B.[Devoted Audit ID]
	WHERE ClientFileProcessDetails_id = @ID
	AND A.VENDOR = 'EXL'
	UNION ALL
	SELECT
		A.Devoted_Audit_ID
	   ,A.Action_Date
	FROM dbo.ADE_AuditStatusUpdateReponse A (NOLOCK)
	JOIN #Outbound_Final B
		ON A.Devoted_Audit_ID = B.[Devoted Audit ID]
	UNION ALL
	SELECT
		A.Devoted_Audit_ID
	   ,A.Action_Date
	FROM dbo.ADE_AuditValidationResponse A (NOLOCK)
	JOIN #Outbound_Final B
		ON A.Devoted_Audit_ID = B.[Devoted Audit ID]
	UNION ALL
	SELECT
		B.[Devoted Audit ID] Devoted_Audit_ID
	   ,CAST(A.[Action Date] AS DATETIME) Action_Date
	FROM dbo.ClientExportAuditStatus A (NOLOCK)
	JOIN #Outbound_Final B
		ON A.[Devoted Audit ID] = B.[Devoted Audit ID]
	UNION ALL
	SELECT
		B.[Devoted Audit ID] Devoted_Audit_ID
	   ,CAST(A.[Action Date] AS DATETIME) Action_Date
	FROM dbo.ClientExportValidationStatus A (NOLOCK)
	JOIN #Outbound_Final B
		ON A.[Devoted Audit ID] = B.[Devoted Audit ID]

INSERT INTO #tempActionDatesFinal
	SELECT
		DevotedAuditId
	   ,MAX(ActionDate) ActionDate
	FROM #tempActionDates
	GROUP BY DevotedAuditId

;
WITH CTE1
AS
(SELECT
		C.DevotedAuditId
	   ,MAX(C.ActionDate) ResponseActionDate
	   ,MIN(CAST(T.[Action Date] AS DATETIME)) OutboundActionDate
	FROM #Outbound_Final T
	JOIN #tempActionDatesFinal C (NOLOCK)
		ON C.DevotedAuditId = T.[Devoted Audit ID]
	GROUP BY C.DevotedAuditId)
SELECT DISTINCT
	A.DevotedAuditId
   ,A.ResponseActionDate
   ,A.OutboundActionDate INTO dbo.#tmpUpdatesRequired
FROM CTE1 A
JOIN #Outbound_Final T
	ON A.DevotedAuditId = T.[Devoted Audit ID]
WHERE A.OutboundActionDate < A.ResponseActionDate

IF(@Debug=0)
BEGIN
INSERT INTO ActionDateUpdateTrack (ClientAuditId, ClientStatus, OldActionDate, StatusActionDate, CreatedAt, NewActionDate, Id)
	SELECT
		[Vendor Audit ID]
	   ,[Status]
	   ,[Action Date]
	   ,C.ResponseActionDate
	   ,GETDATE()
	   ,COALESCE(
		CASE
			WHEN CAST(ResponseActionDate AS TIME) < CAST(OutboundActionDate AS TIME) AND
				DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff'))) < GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff')))
			WHEN CAST(ResponseActionDate AS TIME) < CAST(OutboundActionDate AS TIME) AND
				DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff'))) > GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(GETDATE(), 'HH:mm:ss.fff')))
			WHEN CAST(ResponseActionDate AS TIME) > CAST(OutboundActionDate AS TIME) AND
				DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff'))) < GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff')))
			WHEN CAST(ResponseActionDate AS TIME) > CAST(OutboundActionDate AS TIME) AND
				DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff'))) > GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(GETDATE(), 'HH:mm:ss.fff')))
		END, T.[Action Date])
	   ,T.Rw
	FROM (SELECT
			*
		   ,ROW_NUMBER() OVER (PARTITION BY AuditID ORDER BY CAST(T.[Action Date] AS DATETIME) ASC, T.[SubstatusOrder] ASC) Rw
		FROM dbo.#Outbound_Final T) AS T
	JOIN #tmpUpdatesRequired C
		ON C.DevotedAuditId = T.[Devoted Audit ID]
END

UPDATE T
SET [Action Date] = FORMAT(COALESCE(
CASE
	WHEN CAST(ResponseActionDate AS TIME) < CAST(OutboundActionDate AS TIME) AND
		DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff'))) < GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff')))
	WHEN CAST(ResponseActionDate AS TIME) < CAST(OutboundActionDate AS TIME) AND
		DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(OutboundActionDate, 'HH:mm:ss.fff'))) > GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(GETDATE(), 'HH:mm:ss.fff')))
	WHEN CAST(ResponseActionDate AS TIME) > CAST(OutboundActionDate AS TIME) AND
		DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff'))) < GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff')))
	WHEN CAST(ResponseActionDate AS TIME) > CAST(OutboundActionDate AS TIME) AND
		DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(ResponseActionDate, 'HH:mm:ss.fff'))) > GETDATE() THEN DATEADD(MINUTE, T.Rw, CONCAT(FORMAT(ResponseActionDate, 'yyyy-MM-dd'), ' ', FORMAT(GETDATE(), 'HH:mm:ss.fff')))
END, T.[Action Date]), 'MM/dd/yyyy HH:mm:ss')
FROM (SELECT
		*
	   ,ROW_NUMBER() OVER (PARTITION BY AuditID ORDER BY CAST(T.[Action Date] AS DATETIME) ASC, T.[SubstatusOrder] ASC) Rw
	FROM dbo.#Outbound_Final T) AS T
JOIN #tmpUpdatesRequired C
	ON C.DevotedAuditId = T.[Devoted Audit ID]

UPDATE T
SET [Finding Reason Code] = 'E&MCODE'
FROM #Outbound_Final T
WHERE [Finding Reason Code] = 'E&amp;MCODE '


SELECT
	[AuditID]
   ,[Claimsummaryuid]
   ,[Claimnumber]
   ,[ClaimLineUID]
   ,[Vendor Code]
   ,[Adjudication Record Locator]
   ,[Vendor Audit ID]
   ,[Devoted Audit ID]
   ,[Member Record Locator]
   ,[FDOS]
   ,[Status]
   ,[Level Of Dispute]
   ,[Opportunity Amount]
   ,[Finding Reason Code]
   ,REPLACE([Audit Comments], '"', '') [Audit Comments]
   ,CONVERT(VARCHAR(10), [Action Date], 101) + ' ' + CONVERT(VARCHAR(10), [Action Date], 108) [Action Date]
   ,[Status Reason Code]
   ,[Finding Flag]
FROM #Outbound_Final T
WHERE NOT EXISTS (SELECT
		1
	FROM ClientExportAuditStatus E (NOLOCK)
	WHERE E.ClientAuditId = T.[Vendor Audit Id]
	AND E.StandardSubstatusId = T.StandardSubstatusId
	AND E.[Action Date]>=T.[Action Date])
OR IsLateInventory = 1
ORDER BY T.[Action Date] ASC, T.[SubstatusOrder] ASC, AuditID ASC


IF @Debug = 0
BEGIN
SET XACT_ABORT ON;

DROP TABLE IF EXISTS #InsertedOutbound;

CREATE TABLE dbo.#InsertedOutbound (
	ClientExportAuditStatusId INT
   ,AuditId INT
   ,ClientAuditId BIGINT
   ,DevotedStatus VARCHAR(255)
   ,ActionDate DATETIME
   ,DevotedAuditTransactions_Id INT
);

BEGIN TRY
BEGIN TRANSACTION;
DECLARE @MaxBatchNo INT = 0
SELECT
	@MaxBatchNo = ISNULL(MAX(BatchNo), 0) + 1
FROM dbo.ClientExportAuditStatus

INSERT INTO dbo.ClientExportAuditStatus (BatchNo,
[AuditId],
[ClientAuditId],
[FlowId],
[ClaimsummaryUID],
[Claimnumber],
[ClaimLineUID],
[StandardSubstatus],
[StandardSubstatusId],
[SubstatusOrder],
[Devoted_Status],
[IsCommentMandatory],
[IsOPAmountMandatory],
[IsFindingReasonCodeMandatory],
IsLateInventory,
DevotedAuditTransactions_Id,
[IsFindingFlagRequired],
-- Output Columns --
[Vendor Code],
[Adjudication Record Locator],
[Vendor Audit ID],
[Devoted Audit ID],
[Member Record Locator],
[FDOS],
[Status],
[Level Of Dispute],
[Opportunity Amount],
[Finding Reason Code],
[Audit Comments],
[Action Date],
[Status Reason Code],
ClientFileConfigurationId,
CreatedAt,
[FindingFlag])
OUTPUT INSERTED.Id,
INSERTED.AuditId,
INSERTED.ClientAuditId,
INSERTED.Devoted_Status,
INSERTED.[Action Date],
INSERTED.DevotedAuditTransactions_Id
INTO #InsertedOutbound
(
ClientExportAuditStatusId,
AuditId,
ClientAuditId,
DevotedStatus,
ActionDate,
DevotedAuditTransactions_Id
)
	SELECT
		@MaxBatchNo
	   ,[AuditId]
	   ,[ClientAuditId]
	   ,[FlowId]
	   ,[ClaimsummaryUID]
	   ,[Claimnumber]
	   ,[ClaimLineUID]
	   ,[StandardSubstatus]
	   ,[StandardSubstatusId]
	   ,[SubstatusOrder]
	   ,[Devoted_Status]
	   ,[IsCommentRequired]
	   ,[IsOPAmountRequired]
	   ,[IsFindingReasonCodeRequired]
	   ,IsLateInventory
	   ,DevotedAuditTransactions_Id
	   ,[IsFindingFlagRequired]
		-- Output Columns --
	   ,[Vendor Code]
	   ,[Adjudication Record Locator]
	   ,[Vendor Audit ID]
	   ,[Devoted Audit ID]
	   ,[Member Record Locator]
	   ,[FDOS]
	   ,[Status]
	   ,[Level Of Dispute]
	   ,[Opportunity Amount]
	   ,[Finding Reason Code]
	   ,REPLACE([Audit Comments], '"', '') [Audit Comments]
	   ,CONVERT(VARCHAR(10), [Action Date], 101) + ' ' + CONVERT(VARCHAR(10), [Action Date], 108) [Action Date]
	   ,[Status Reason Code]
	   ,@ClientFileConfigurationId
	   ,GETDATE()
	   ,[Finding Flag]
	FROM #Outbound_Final T
	WHERE NOT EXISTS (SELECT
			1
		FROM ClientExportAuditStatus CFS (NOLOCK)
		WHERE CFS.ClientAuditId = T.[Vendor Audit Id]
		AND CFS.StandardSubstatusId = T.StandardSubstatusId
	AND CFS.[Action Date]>=T.[Action Date])
	OR IsLateInventory = 1

/*Changed on 09/09 - Duplicate Issue Fix in AuditTransitinobaseline*/
;WITH LatestAudit AS
(
SELECT
    O.AuditId,
    O.ClientAuditId,
    O.DevotedStatus,
    O.ActionDate,
    ROW_NUMBER() OVER(PARTITION BY O.AuditId ORDER BY O.ActionDate DESC) AS Rw
FROM #InsertedOutbound O
INNER JOIN #ValidationData V ON V.DevotedAuditTransactions_Id = O.DevotedAuditTransactions_Id
WHERE V.IsValid = 1 AND ISNULL(V.PreviousStatus, '') <> ISNULL(V.CurrentStatus, '') AND O.DevotedStatus IS NOT NULL
),
SourceData AS
(SELECT AuditId,ClientAuditId,DevotedStatus,ActionDate FROM LatestAudit WHERE Rw = 1
)
MERGE dbo.AuditTransitionBaseline WITH (HOLDLOCK) AS B
USING SourceData AS S
    ON B.AuditId = S.AuditId

WHEN MATCHED
	THEN UPDATE
		SET BaselineStatus = S.DevotedStatus
		   ,ActionDate = S.[ActionDate]
		   ,LastUpdatedAt=GETDATE()/*Changed on 09/02*/

WHEN NOT MATCHED
	THEN INSERT (AuditId
		, ClientAuditId
		, BaselineStatus
		, ActionDate,CreatedAt,FileExchangeTypeId)/*Changed on 09/02*/
			VALUES (S.AuditId, S.ClientAuditId, S.DevotedStatus, S.[ActionDate],GETDATE(),@FileExchangeTypeId);


UPDATE D
SET IsReported = 1
   ,ReportedDate = GETDATE()
FROM dbo.#InsertedOutbound A
JOIN dbo.DevotedAuditTransactions D
	ON A.DevotedAuditTransactions_Id = D.Id
WHERE D.IsReported = 0
AND D.FileExchangeTypeId = @FileExchangeTypeId

UPDATE V
SET V.WasExported = 1
FROM dbo.AuditStatusTransitionValidation V
INNER JOIN #InsertedOutbound I
	ON I.DevotedAuditTransactions_Id =
	V.DevotedAuditTransactions_Id
WHERE V.BatchNo = @BatchNo;

UPDATE R
SET R.IsReported = 1
FROM ReportDisputeLevel3 R
JOIN dbo.ClientExportAuditStatus CE (NOLOCK)
	ON R.AuditId = CE.AuditId
	AND CAST(R.LevelOfDispute AS VARCHAR) = CE.[Level Of Dispute]
WHERE R.IsReported = 0

UPDATE F
SET FixStatus = 'Closed'
   ,FixedDate = GETDATE()
FROM FileExchangeException F
JOIN ClientExportAuditStatus C (NOLOCK)
	ON F.ClientAuditId = C.ClientAuditId
	AND F.DevotedStatus = C.Devoted_Status
WHERE F.FixStatus = 'Open'
AND FileExchangeTypeId = 3

/*Remove Not A True Level 3 Dispute - Added By Siva Subramanian 10/9/2025*/
UPDATE A
SET FixStatus = 'Closed'
   ,FixedDate = GETDATE()
FROM dbo.FileExchangeException A
JOIN dbo.AuditDetails B (NOLOCK)
	ON A.AuditId = B.AuditId
WHERE FixStatus = 'Open'
AND ErrorMessage = 'Level 3 Dispute'
AND B.Substatus NOT IN ('Received Level 3 Dispute', 'Sent to Client Level 3 Dispute', 'Pended to Client Level 3 Dispute', 'Pended Level 3 Dispute to Client Sent', 'Pended Level 2 Dispute to Client Sent')

INSERT INTO ReportLateInventoryArchive
	SELECT
		AuditID
	   ,Flow_id
	   ,Substatus_id
	   ,Substatus
	   ,StandardSubStatusId
	   ,StandardSubstatus
	   ,DateMovedIntoSubstatus
	   ,1
	   ,GETDATE()
	FROM ReportLateInventory

DELETE FROM ReportLateInventory --WHERE IsReportedToClient=0

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
IF XACT_STATE() <> 0
ROLLBACK TRANSACTION;

THROW;
END CATCH;

EXEC [USP_MailFileExchangeExceptions] @FileExchangeTypeId

IF EXISTS (SELECT
			1
		FROM #InsertedOutbound)
BEGIN
EXEC [USP_MailFileExchangeAlert] @FileExchangeTypeId
END
END
END
END
