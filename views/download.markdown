### Download TF binding peak data

The detailed data of TF binding peak including location of the location of the peaks and the distance to the nearest transcription start site (TSS) annotated using the Bioconductor package ChIPpeakAnno and TSS annotation data “TSS.mouse.NCBIM37”.

- TF: The Uniprot symbol of transcription factor
- peak file: The name of the peak file. The corresponding TF and cell types can be found in the meta data (wPGSA_data_info.xlsx)
- space: The name of the chromosome
- start: The starting position of the peak in the chromosome
- end: The ending position of the peak in the chromosome
- width: The width of the peak
- strand: Either ‘+’ or ‘-‘. If ‘-‘, then the alignment of the feature is to the reverse-complemented source (usually ‘+')
- feature: The Ensemble Gene ID of the nearest gene
- start_position: The starting position of the nearest gene
- end_position: The ending position of the nearest gene
- feature_strand: The strand of the nearest gene
- insideFeature:
	- upstream: peak resides upstream of the gene gene
	- downstream: peak resides down-stream of the gene
	- inside: peak resides inside the gene
	- overlapStart: peak overlaps with the start of the gene
	- overlapEnd: peak overlaps with the end of the gene
	- includeFeature: peak include the gene (impractical)
- distancetoFeature: distance between the start of the peak and the TSS of the nearest gene

[Download TF binding peak data](http://web.ims.riken.jp/en/paper_data/wPGSA_ChIPpeak_detailed_info.tar.bz2)

### Download ChIP data list

ChIP data list provides metadata for each ChIP experiment.

[Donwload data list (.xlsx)](/data/wPGSA_data_info.xlsx)
