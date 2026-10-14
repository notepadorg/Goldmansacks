USE [DevotedHealthPrepayAuditClaims]
GO
/****** Object:  StoredProcedure [dbo].[Audit_Comments_Update_Status_File_PrePay]    Script Date: 10/14/2026 2:56:29 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--==================================================      
-- Name   : Audit_Comments_Update_Status_File      
-- Description : Concatinating the additional DRG and Procedure code fields to the existing audit comments field.   
-- Created date : 09/11/2026     
-- Created by : Sakthivelu Sekar     
-- Sample EXECUTION:  
-- EXEC [dbo].[Audit_Comments_Update_Status_File]     
--==================================================  
ALTER            PROCEDURE [dbo].[Audit_Comments_Update_Status_File_PrePay] 
AS
BEGIN
		
		DECLARE @SQLQUERY NVARCHAR(MAX);
		DECLARE @WorkFlowDatabseName varchar(max) = 'Workflow_DevotedHealthPrepay';
		DECLARE @Databasename varchar(max) = 'DevotedHealthPrepayAuditClaims';


/* ===================== FLOW 1 ===================== */
PRINT 'START-1'

		SET @SQLQUERY = N'
		;WITH FilteredOutbound_1 AS
		(
			SELECT T.*
			FROM #OutBoundResult T
			WHERE NOT EXISTS
			(
					SELECT 1 FROM ' + QUOTENAME(@Databasename) + '..ClientExportAuditStatus E WITH(NOLOCK)
					WHERE E.ClientAuditId = T.VendorAuditID AND E.StandardSubstatusId= T.StandardSubstatusId
			) 
			AND T.FlowID = 1 AND NOT 
			(
					ISNULL(T.IsCommentRequired,0) = 0 AND ISNULL(T.IsFindingReasonCodeRequired,0) = 0
			) AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')
		)';
		
		SET @SQLQUERY += N'
		,BaseAudit_1 AS
		(
			SELECT  DISTINCT A.Id,A.ClaimSummaryUid
			FROM FilteredOutbound_1 T
			 JOIN ' + QUOTENAME(@WorkFlowDatabseName) + '..Audit a WITH(NOLOCK) on a.Id = T.Audit_Id
		)';

		SET @SQLQUERY +=N'
		,CTE_1 AS 
		(
			SELECT 
				a1.Id As AuditId,
				DenialReason = LEFT(cv.Initial_Denial_Reason_00, CHARINDEX('' '',cv.Initial_Denial_Reason_00 + '' '') - 1),
			   CodeToBeDenied = CASE WHEN ISNULL(LTRIM(RTRIM(ul.HCPCSCode)),'''') <> '''' THEN ul.HCPCSCode else ul.CPTCode END,    
			   UnitsDenied = ISNULL(ul.ServiceUnitCount,0) - ISNULL(cv.Initial_Units_Validated,0),
			   DateOfService = FORMAT(ul.FirstDateOfService,''M/d/yy'')
						FROM   BaseAudit_1 a1
						JOIN ' + QUOTENAME(@Databasename) + '..Claimsummary cs WITH(NOLOCK) 
						on cs.ClaimSummaryUID = a1.ClaimSummaryUid
						join ' + QUOTENAME(@Databasename) + '..claimline ul WITH(NOLOCK) on ul.ClaimSummaryUID = A1.ClaimSummaryUID
						join ' + QUOTENAME(@WorkFlowDatabseName) + '..CustomValues1 cv WITH(NOLOCK)
						on cv.Audit_id = a1.Id and cv.ClaimLineUid = ul.ClaimLineUid
						WHERE  ISNULL(cv.Initial_Auditor_Comments,'''') <> '''' and cv.Is_Note_Billable = ''No'' 						
										
				) ';
				SET @SQLQUERY += N'
				,Grouped_1 AS
				(
					Select 
						c1.AuditId,
						c1.DenialReason,
						c1.CodeToBeDenied,
						STUFF
						(
							(
								SELECT 
									'','' +CAST(c2.UnitsDenied AS VARCHAR(20))
									from CTE_1  c2
									where c2.AuditId = c1.AuditId
									and c2.DenialReason = c1.DenialReason
									and c2.CodeToBeDenied = c1.CodeToBeDenied
									FOR XML PATH(''''), TYPE
									).value(''.'',''nvarchar(max)''),1,1,'''')As UnitsDenied,
						STUFF
						(
							(
								SELECT 
									'','' +c2.DateOfService
									from CTE_1  c2
									where c2.AuditId = c1.AuditId
									and c2.DenialReason = c1.DenialReason
									and c2.CodeToBeDenied = c1.CodeToBeDenied
									FOR XML PATH(''''), TYPE
									).value(''.'',''nvarchar(max)''),1,1,'''')As DOS
						from CTE_1 c1
						group by 
						AuditId,
						DenialReason,
						CodeToBeDenied
				)';

				SET @SQLQUERY += N'
				,Final_1 AS 
				(
					SELECT  g.AuditId as Audit_Id,
						STUFF
						(
							(
								SELECT  
								''*****Denial Reason code: '' +  ISNULL(g2.DenialReason,''N/A'') +
								+
								''****Code(s) to be denied: '' + ISNULL(g2.CodeToBeDenied,''N/A'') 
								+
								''****Units Denied: '' + ISNULL(CAST(g2.UnitsDenied AS VARCHAR(MAX)),''N/A'')
								+
								''****Date of Service :'' + ISNULL(g2.DOS,''N/A'')
								from Grouped_1 g2
								where g2.AuditId = g.AuditId
								for XML PATH(''''),TYPE
								).value(''.'',''nvarchar(max)''),1,2,''''
						) AS FinalResult
					FROM Grouped_1 g
					group by g.AuditId
				)';

				SET @SQLQUERY += N'
				Update T SET [AuditComments] = CONCAT([AuditComments],R.FinalResult)
					from #OutBoundResult T
					LEFT JOIN Final_1 R
					ON R.Audit_Id = T.Audit_Id
					where FlowID = 1 AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')';
					

--SELECT LEN(@SQLQUERY)
--SELECT DATALENGTH(@SQLQUERY)
--SELECT RIGHT(@SQLQUERY,500);

--SELECT SUBSTRING(@SQLQUERY,1,2000)
--SELECT SUBSTRING(@SQLQUERY,2001,2000)
--SELECT SUBSTRING(@SQLQUERY,4001,2000)
--SELECT SUBSTRING(@SQLQUERY,6001,2000)
--SELECT SUBSTRING(@SQLQUERY,8001,2000)


				EXEC sp_executesql @SQLQUERY;
PRINT 'END-1'


/* ===================== FLOW 101 ===================== */
PRINT 'START-101'

		SET @SQLQUERY = N'
		;WITH FilteredOutbound_101 AS
		(
			SELECT T.*
			FROM #OutBoundResult T
			WHERE NOT EXISTS
			(
					SELECT 1 FROM ' + QUOTENAME(@Databasename) + '..ClientExportAuditStatus E WITH(NOLOCK)
					WHERE E.ClientAuditId = T.VendorAuditID AND E.StandardSubstatusId= T.StandardSubstatusId
			) 
			AND T.FlowID = 101 AND NOT 
			(
					ISNULL(T.IsCommentRequired,0) = 0 AND ISNULL(T.IsFindingReasonCodeRequired,0) = 0
			)AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')
		)';
		
		SET @SQLQUERY += N'
		,BaseAudit_101 AS
		(
			SELECT  DISTINCT A.Id,A.ClaimSummaryUid
			FROM FilteredOutbound_101 T
			 JOIN ' + QUOTENAME(@WorkFlowDatabseName) + '..Audit a WITH(NOLOCK) on a.Id = T.Audit_Id
		)';

		SET @SQLQUERY +=N'
		,CTE_101 AS 
		(
			SELECT 
				a1.Id As AuditId,
				DenialReason = LEFT(cv.Initial_Denial_Reason_00, CHARINDEX('' '',cv.Initial_Denial_Reason_00 + '' '') - 1),
			   CodeToBeDenied = CASE WHEN ISNULL(LTRIM(RTRIM(ul.HCPCSCode)),'''') <> '''' THEN ul.HCPCSCode else ul.CPTCode END,    
			   UnitsDenied = ISNULL(ul.ServiceUnitCount,0) - ISNULL(cv.Initial_Units_Validated,0),
			   DateOfService = FORMAT(ul.FirstDateOfService,''M/d/yy'')
						FROM   BaseAudit_101 a1
						JOIN ' + QUOTENAME(@Databasename) + '..Claimsummary cs WITH(NOLOCK) 
						on cs.ClaimSummaryUID = a1.ClaimSummaryUid
						join ' + QUOTENAME(@Databasename) + '..claimline ul WITH(NOLOCK) on ul.ClaimSummaryUID = A1.ClaimSummaryUID
						join ' + QUOTENAME(@WorkFlowDatabseName) + '..CustomValues101 cv WITH(NOLOCK)
						on cv.Audit_id = a1.Id and cv.ClaimLineUid = ul.ClaimLineUid
						WHERE  ISNULL(cv.Initial_Auditor_Comments,'''') <> '''' and cv.Is_Note_Billable = ''No'' 						
										
				) ';
				SET @SQLQUERY += N'
				,Grouped_101 AS
				(
					Select 
						c1.AuditId,
						c1.DenialReason,
						c1.CodeToBeDenied,
						STUFF
						(
							(
								SELECT 
									'','' +CAST(c2.UnitsDenied AS VARCHAR(20))
									from CTE_101  c2
									where c2.AuditId = c1.AuditId
									and c2.DenialReason = c1.DenialReason
									and c2.CodeToBeDenied = c1.CodeToBeDenied
									FOR XML PATH(''''), TYPE
									).value(''.'',''nvarchar(max)''),1,1,'''')As UnitsDenied,
						STUFF
						(
							(
								SELECT 
									'','' +c2.DateOfService
									from CTE_101  c2
									where c2.AuditId = c1.AuditId
									and c2.DenialReason = c1.DenialReason
									and c2.CodeToBeDenied = c1.CodeToBeDenied
									FOR XML PATH(''''), TYPE
									).value(''.'',''nvarchar(max)''),1,1,'''')As DOS
						from CTE_101 c1
						group by 
						AuditId,
						DenialReason,
						CodeToBeDenied
				)';

				SET @SQLQUERY += N'
				,Final_101 AS 
				(
					SELECT  g.AuditId as Audit_Id,
						STUFF
						(
							(
								SELECT  
								''*****Denial Reason code: '' +  ISNULL(g2.DenialReason,''N/A'') +
								+
								''****Code(s) to be denied: '' + ISNULL(g2.CodeToBeDenied,''N/A'') 
								+
								''****Units Denied: '' + ISNULL(CAST(g2.UnitsDenied AS VARCHAR(MAX)),''N/A'')
								+
								''****Date of Service :'' + ISNULL(g2.DOS,''N/A'')
								from Grouped_101 g2
								where g2.AuditId = g.AuditId
								for XML PATH(''''),TYPE
								).value(''.'',''nvarchar(max)''),1,2,''''
						) AS FinalResult
					FROM Grouped_101 g
					group by g.AuditId
				)';

				SET @SQLQUERY += N'
				Update T SET [AuditComments] = CONCAT([AuditComments],R.FinalResult)
					from #OutBoundResult T
					LEFT JOIN Final_101 R
					ON R.Audit_Id = T.Audit_Id
					where FlowID = 101 AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')';
					

--SELECT LEN(@SQLQUERY)
--SELECT DATALENGTH(@SQLQUERY)
--SELECT RIGHT(@SQLQUERY,500);

--SELECT SUBSTRING(@SQLQUERY,1,2000)
--SELECT SUBSTRING(@SQLQUERY,2001,2000)
--SELECT SUBSTRING(@SQLQUERY,4001,2000)
--SELECT SUBSTRING(@SQLQUERY,6001,2000)
--SELECT SUBSTRING(@SQLQUERY,8001,2000)


				EXEC sp_executesql @SQLQUERY;
PRINT 'END-101'


/* ===================== FLOW 303 : DEVOTED HOME HEALTH (HIPPS) ===================== */
PRINT 'START-303'

		SET @SQLQUERY = N'
		;WITH FilteredOutbound_303 AS
		(
			SELECT T.*
			FROM #OutBoundResult T
			WHERE NOT EXISTS
			(
					SELECT 1 FROM ' + QUOTENAME(@Databasename) + '..ClientExportAuditStatus E WITH(NOLOCK)
					WHERE E.ClientAuditId = T.VendorAuditID AND E.StandardSubstatusId= T.StandardSubstatusId
			) 
			AND T.FlowID = 303 AND NOT 
			(
					ISNULL(T.IsCommentRequired,0) = 0 AND ISNULL(T.IsFindingReasonCodeRequired,0) = 0
			) AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')
		)';

		SET @SQLQUERY += N'
		,BaseAudit_303 AS
		(
			SELECT  DISTINCT A.Id,A.ClaimSummaryUid
			FROM FilteredOutbound_303 T
			 JOIN ' + QUOTENAME(@WorkFlowDatabseName) + '..Audit a WITH(NOLOCK) on a.Id = T.Audit_Id
		)';

		-- Step 1: get the data and remove the word LUPA
		SET @SQLQUERY += N'
		,Base_303 AS
		(
			SELECT 
				a1.Id AS AuditId,
				DenialCode = LTRIM(RTRIM(
					CASE WHEN CHARINDEX(''-'', cv.Client_Denied_Findings_Reason_Code) > 0
						 THEN LEFT(cv.Client_Denied_Findings_Reason_Code, CHARINDEX(''-'', cv.Client_Denied_Findings_Reason_Code) - 1)
						 ELSE cv.Client_Denied_Findings_Reason_Code
					END)),
				DOS    = CONVERT(VARCHAR(10), cs.FirstDateOfService, 101),
				Billed = LTRIM(RTRIM(REPLACE(ISNULL(cv.HIPPS_Code_Billed, ''''), ''LUPA'', ''''))),
				Found  = LTRIM(RTRIM(REPLACE(ISNULL(cv.Initial_Review_HIPPS_Code_Found, ''''), ''LUPA'', '''')))
			FROM BaseAudit_303 a1
			JOIN ' + QUOTENAME(@Databasename) + '..ClaimSummary cs WITH(NOLOCK)
				ON cs.ClaimSummaryUID = a1.ClaimSummaryUid
			JOIN ' + QUOTENAME(@WorkFlowDatabseName) + '..CustomValues303 cv WITH(NOLOCK)
				ON cv.Audit_ID = a1.Id
			WHERE cv.ClaimLineUID IS NULL
			  AND cv.Initial_Review_HIPPS_Code_Found NOT IN (''None'', ''NULL'')
		)';

		-- Step 2: split Billed and Found on 'updated to'
		SET @SQLQUERY += N'
		,Split_303 AS
		(
			SELECT 
				b.AuditId, b.DenialCode, b.DOS, b.Billed, b.Found,
				B1 = LTRIM(RTRIM(CASE WHEN bp.Pos > 0 THEN LEFT(b.Billed, bp.Pos - 1) ELSE b.Billed END)),
				B2 = CASE WHEN bp.Pos > 0 THEN LTRIM(RTRIM(SUBSTRING(b.Billed, bp.Pos + 10, 8000))) END,
				F1 = LTRIM(RTRIM(CASE WHEN fp.Pos > 0 THEN LEFT(b.Found, fp.Pos - 1) ELSE b.Found END)),
				F2 = CASE WHEN fp.Pos > 0 THEN LTRIM(RTRIM(SUBSTRING(b.Found, fp.Pos + 10, 8000))) END
			FROM Base_303 b
			CROSS APPLY (SELECT Pos = CHARINDEX(''updated to'', b.Billed)) bp
			CROSS APPLY (SELECT Pos = CHARINDEX(''updated to'', b.Found))  fp
		)';

		-- Step 3: build the pairs
		SET @SQLQUERY += N'
		,Pairs_303 AS
		(
			SELECT 
				AuditId, DenialCode, DOS,
				Seq = 1,
				HIPPS    = CASE WHEN B2 IS NULL AND F2 IS NOT NULL THEN F1 ELSE B1 END,
				AltHIPPS = CASE WHEN Billed = Found                THEN ISNULL(B2, B1)
								WHEN B2 IS NOT NULL AND F2 IS NULL THEN B2
								WHEN B2 IS NULL AND F2 IS NOT NULL THEN F2
								ELSE F1
						   END
			FROM Split_303

			UNION ALL

			SELECT AuditId, DenialCode, DOS, 2, B2, F2
			FROM Split_303
			WHERE B2 IS NOT NULL 
			  AND F2 IS NOT NULL 
			  AND Billed <> Found
		)';

		SET @SQLQUERY += N'
		,Final_303 AS
		(
			SELECT 
				p.AuditId AS Audit_Id,
				STUFF((
					SELECT '', '' +
						   ''****Denial Reason Code: '' + ISNULL(NULLIF(p2.DenialCode, ''''), ''N/A'') +
						   '', ****HIPPS Denied: ''     + ISNULL(NULLIF(p2.HIPPS, ''''), ''N/A'') +
						   '', ****HIPPS Changed: ''    + ISNULL(NULLIF(p2.AltHIPPS, ''''), ''N/A'') +
						   '' ****Date of Service: ''   + ISNULL(p2.DOS, ''N/A'')
					FROM Pairs_303 p2
					WHERE p2.AuditId = p.AuditId
					ORDER BY p2.Seq
					FOR XML PATH(''''), TYPE
				).value(''.'', ''nvarchar(max)''), 1, 2, '''') AS FinalResult
			FROM Pairs_303 p
			GROUP BY p.AuditId
		)';

		SET @SQLQUERY += N'
		Update T SET [AuditComments] = CONCAT([AuditComments],R.FinalResult)
			from #OutBoundResult T
			LEFT JOIN Final_303 R
			ON R.Audit_Id = T.Audit_Id
			where FlowID = 303 AND ISNULL(LTRIM(RTRIM([FindingReasonCode])), '''') NOT IN ('''', ''NOFINDING'')';

		EXEC sp_executesql @SQLQUERY;
PRINT 'END-303'


END
