<#
.Synopsis
   Parse Nessus XML report and import into Elasticsearch using the _bulk API.
.DESCRIPTION
   Parse Nessus XML report and convert to expected json format (x-ndjson)
   for Elasticsearch _bulk API.

   Original script credit found here --> https://github.com/iwikmai/Nessus-ES/blob/master/ImportTo-ElasticSearchBulk.ps1

   How to create and use an API key for Elastic can be found here: https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-create-api-key.html

   Tested for Elastic Stack 7.6.1 - Should work on 7.0+, not tested on older clusters.

.EXAMPLE
   .\ImportTo-Elasticsearch-Nessus.ps1 -InputXML "C:\folder\file.nessus" -ElasticsearchURL "https://localhost:9200" -Index "nessus" -ApiKey "redacted"
#>

[CmdletBinding()]
[Alias()]
Param
(
    # XML file input
    [Parameter(Mandatory=$true,
                ValueFromPipelineByPropertyName=$true,
                Position=0)]
    $InputXML,
    # Elasticsearch endpoint
    [Parameter(Mandatory=$false,
                ValueFromPipelineByPropertyName=$true,
                Position=1)]
    $ElasticsearchURL,
    # Elasticsearch index mapping
    [Parameter(Mandatory=$false,
                ValueFromPipelineByPropertyName=$true,
                Position=2)]
    $Index,
    # Elasticsearch API Key
    [Parameter(Mandatory=$false,
                ValueFromPipelineByPropertyName=$true,
                Position=3)]
    $ApiKey
)

Begin{
    #Trust certs
    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    $ErrorActionPreference = 'Stop'
    $nessus = [xml]''
    $nessus.Load($InputXML)
}
Process{
    #Elastic Instance (Hard code values here)
    $ElasticsearchIP = '127.0.0.1'
    $ElasticsearchPort = '9200'
    if($ElasticsearchURL){Write-Host "Using the URL you provided for Elastic: $ElasticsearchURL" -ForegroundColor Green}else{$ElasticsearchURL = "https://"+$ElasticsearchIP+":"+$ElasticsearchPORT; Write-Host "Running script with manual configuration, will use static variables ($ElasticsearchURL)." -ForegroundColor Yellow}
    #Nessus User Authenitcation Variables for Elastic
    if($ApiKey){Write-Host "Using the Api Key you provided." -ForegroundColor Green}else{Write-Host "ApiKey Required! Go here if you don't know how to obtain one - https://www.elastic.co/guide/en/elasticsearch/reference/current/security-api-create-api-key.html" -ForegroundColor "Red"; break;}
    $global:AuthenticationHeaders = @{Authorization = "ApiKey $apiKey"}

    #Create index name
    if($Index){Write-Host "Using the Index you provided: $Index" -ForegroundColor Green}else{$Index = "nessus-2020"; Write-Host "No Index was entered, using the default value of $Index" -ForegroundColor Yellow}
    
    #Now let the magic happen!
    Write-Host "
    Starting ingest of $InputXML.

    The time it takes to parse and ingest will vary on the file size. 
     
    Note: Files larger than 1GB could take over 35 minutes.

    You can check if data is getting ingested by visiting Kibana and look under Index Management for this index: $Index

    For debugging uncomment line 202.
    "
    $fileProcessed = (Get-ChildItem $InputXML).name
    $reportName = $nessus.NessusClientData_v2.Report.name
    foreach ($n in $nessus.NessusClientData_v2.Report.ReportHost){
        foreach($r in $n.ReportItem){
            foreach ($nHPTN_Item in $n.HostProperties.tag){
            #Get useful tag information from the report
            switch -Regex ($nHPTN_Item.name)
                {
                "host-ip" {$ip = $nHPTN_Item."#text"}
                "host-fqdn" {$fqdn = $nHPTN_Item."#text"}
                "host-rdns" {$rdns = $nHPTN_Item."#text"}
                "operating-system-unsupported" {$osu = $nHPTN_Item."#text"}
                "system-type" {$systype = $nHPTN_Item."#text"}
                "^os$" {$os = $nHPTN_Item."#text"}
                "operating-system$" {$opersys = $nHPTN_Item."#text"}
                "operating-system-conf" {$operSysConfidence = $nHPTN_Item."#text"}
                "operating-system-method" {$operSysMethod = $nHPTN_Item."#text"}
                "^Credentialed_Scan" {$credscan = $nHPTN_Item."#text"}
                "mac-address" {$macAddr = $nHPTN_Item."#text"}
                "HOST_START_TIMESTAMP$" {$hostStart = $nHPTN_Item."#text"}
                "HOST_END_TIMESTAMP$" {$hostEnd = $nHPTN_Item."#text"}
                }
            }
            #Convert seconds to milliseconds
            $hostStart = [int]$hostStart*1000
            $hostEnd = [int]$hostEnd*1000
            #Convert milliseconds to nano seconds
            $duration = $(($hostEnd - $hostStart)*1000000)

            $obj=[PSCustomObject]@{
                "@timestamp" = $hostStart #Remove later for at ingest enrichment
                "destination" = [PSCustomObject]@{
                    "port" = $r.port
                }
                "ecs" = [PSCustomObject]@{
                    "version" = "1.5"
                }                
                "event" = [PSCustomObject]@{
                    "category" = "host" #Remove later for at ingest enrichment
                    "kind" = "state" #Remove later for at ingest enrichment
                    "duration" = $duration
                    "start" = $hostStart
                    "end" = $hostEnd
                    "risk_score" = $r.severity
                    "dataset" = "vulnerability" #Remove later for at ingest enrichment
                    "provider" = "Nessus" #Remove later for at ingest enrichment
                    "message" = $n.name + ' - ' + $r.synopsis #Remove later for at ingest enrichment
                    "module" = "ImportTo-Elasticsearch-Nessus"
                    "severity" = $r.severity #Remove later for at ingest enrichment
                    "url" = (@(if($r.cve){($r.cve | ForEach-Object {"https://cve.mitre.org/cgi-bin/cvename.cgi?name=$_"})}else{$null})) #Remove later for at ingest enrichment
                }
                "host" = [PSCustomObject]@{
                    "ip" = $ip
                    "mac" = (@(if($macAddr){($macAddr.Split([Environment]::NewLine))}else{$null}))
                    "hostname" = if($fqdn){$fqdn}elseif($rdns){$rdns}else{$null}
                    "name" = if($fqdn){$fqdn}elseif($rdns){$rdns}else{$null}
                    "os" = [PSCustomObject]@{
                        "family" = $os
                        "full" = @(if($opersys){$opersys.Split("`n`r")}else{$null})
                        "name" = @(if($opersys){$opersys.Split("`n`r")}else{$null})
                        "platform" = $os
                    }
                }
                "log" = [PSCustomObject]@{
                    "origin" = [PSCustomObject]@{
                        "file" = [PSCustomObject]@{
                            "name" =  $fileProcessed
                        }
                    }
                }
                "nessus" = [PSCustomObject]@{
                    "cve" = (@(if($r.cve){($r.cve).ToLower()}else{$null}))
                    "in_the_news" = if($r.in_the_news){$r.in_the_news}else{$null}
                    "solution" = $r.solution
                    "synopsis" = $r.synopsis
                    "unsupported_os" = if($osu){$osu}else{$null}
                    "system_type" = $systype
                    "credentialed_scan" = $credscan
                    "exploit_available" = $r.exploit_available
                    "edb-id" = $r."edb-id"
                    "unsupported_by_vendor" = $r.unsupported_by_vendor
                    "os_confidence" = $operSysConfidence
                    "os_identification_method" = $operSysMethod
                    "rdns" = $rdns
                    "name_of_host" = $n.name
                    "cvss" = [PSCustomObject]@{
                        "vector" = $r.cvss_vector
                    }
                    "plugin" = [PSCustomObject]@{
                        "id" = $r.pluginID
                        "name" = $r.pluginName
                        "date" = $r.plugin_publication_date
                        "type" = $r.plugin_type
                        "output" = $r.plugin_output
                    }
                }
                "network" = [PSCustomObject]@{
                    "transport" = $r.protocol
                    "application" = $r.svc_name
                }
                "vulnerability" = [PSCustomObject]@{
                    "id" = (@(if($r.cve){($r.cve)}else{$null}))
                    "category" = $r.pluginFamily
                    "description" = $r.description
                    "severity" = $r.risk_factor
                    "reference" = (@(if($r.see_also){($r.see_also.Split([Environment]::NewLine))}else{$null}))
                    "report_id" = $reportName
                    "module" = $r.pluginName #Remove later for at ingest enrichment
                    "classification" = (@(if($r.cve){("CVE")}else{$null})) #Remove later for at ingest enrichment
                    "score" = [PSCustomObject]@{
                            "base" = $r.cvss_base_score
                            "temporal" = $r.cvss_temporal_score
                    }
                }

            } | ConvertTo-Json -Compress -Depth 5
            
            $hash += "{`"index`":{`"_index`":`"$Index`"}}`r`n$obj`r`n"
            #$Clean up variables
            $ip = ''
            $fqdn = ''
            $osu = ''
            $systype = ''
            $os = ''
            $opersys = ''
            $credscan = ''
            $macAddr = ''
            $hostStart = ''
            $hostEnd = ''
            $cves = ''
            $rdns = ''
            $operSysConfidence = ''
            $operSysMethod = ''

        }
        #Uncomment below to see the hash
        #$hash
        $ProgressPreference = 'SilentlyContinue'
        $data = Invoke-RestMethod -Uri "$ElasticsearchURL/_bulk" -Method POST -ContentType "application/x-ndjson" -body $hash -Headers $global:AuthenticationHeaders
        #Error checking
        #$data.items | ConvertTo-Json -Depth 5
        
        $hash = ''
    }
}
End{
    Write-Host "End of exporting!" -ForegroundColor Green
}
