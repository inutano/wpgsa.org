### About input data format

Log fold change data should be prepared in an ASCII tab delimited text file. It is organized as follows.  
To create and edit the log fold change file, use a text editor or Excel. When you use Excel, be aware of a problem as described in [Zeeberg et al 2004](http://www.ncbi.nlm.nih.gov/pubmed/15214961).

![dataformat](/images/dataformat.pdf)

The first line contains the identifiers for each sample in the dataset  
Line format: Gene Symbol(tab)(sample1 name)(tab)(sample2 name)(tab) … (sampleN name)  
Example:     Gene Symbol(tab)K_Virus_0(tab)K_Virus_3(tab) … K_Virus_D7

The remainder of the lines contains log fold change (LFC) data for each of the genes.  
Line format: (gene name)(tab)(LFC of sample1)(tab)(LFC of sample2)(tab) … (LFC of sampleN)  
Example:     Plekhg2(tab)-0.092(tab)0.170(tab) … 0.047
