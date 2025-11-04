"""
Note that we are declaring many files temporary here that should be located in a temporary folder to begin with
"""


# container with conda environments
containerized: "docker://visze/cadd-scripts-v1_7:0.1.0"

# need glob to get chunked files
import psutil 

# Min version of snakemake
from snakemake.utils import min_version

min_version("7.32.3")

# Validation of config file
from snakemake.utils import validate

validate(config, schema="schemas/config_schema.yaml")

# CADD environment variable
import os

###################################
## RULE SPECFIC THREADING LIMITS ##
###################################
if int(config.get("mem_gb",0)) == 0:
    system_memory = psutil.virtual_memory().total / (1024 ** 3)
else:
    system_memory = int(config["mem_gb"])
try:
    lines = subprocess.check_output("nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null", shell=True).decode('utf-8').splitlines()
    # sum over gpu(s)
    gpu_memory = int(sum([int(x) for x in lines])/1024)
    # nr of gpus
    gpu_count = len(lines)
except Exception as e:
    gpu_memory = 0
    gpu_count = 0
    pass

###############
## GPU TASKS ##
###############
# esm takes ~16 Gb of system memory per tread & 14 Gb of GPU ram (if available). 
# if gpu is available, we can use it for esm : one thread per gpu.
if gpu_count > 0:
    config['esm_cpu_slots'] = int(max(1,(0.9*system_memory)/16))
    config['esm_gpu_slots'] = int(0.9*gpu_memory/14)
else:
    config['esm_cpu_slots'] = int(max(1,0.9*system_memory / 16))
    config['esm_gpu_slots'] = 0
config['esm_cpu_load'] = int(100/config['esm_cpu_slots']) 
config['esm_gpu_load'] = 100 if config['esm_gpu_slots'] < 1 else int(100/config['esm_gpu_slots'])
config['esm_cpu_threads'] = max(1, int(workflow.cores /  config['esm_cpu_slots']))

###############
## CPU TASKS ##
###############
# then assign other resources
config['vep_cpu_load'] = 100 if system_memory < 4 else int(100/int(0.9*system_memory / 4 ))  # up to 4Gb/ram
config['vep_cpu_threads'] = max(1, int(workflow.cores / (100/config['vep_cpu_load'])))
config['regseq_cpu_load'] = 100 if system_memory < 2 else int(100/int(0.9*system_memory / 2 ))   # up to 2Gb of ram
config['mms_cpu_load'] = 100 if system_memory < 16 else int(100/int(0.9*system_memory / 16 ))   # up to 16Gb/ram
config['mms_cpu_threads'] = max(1, int(workflow.cores / (100/config['mms_cpu_load'])))
config['anno_cpu_load'] = 1 # disk IO intensive
config['impute_cpu_load'] = 1 
config['prescore_cpu_load'] = 10  # disk IO intensive 
config['score_cpu_load'] = 1

print("Threading Overview")
print("##################")
print("Assigned cores: {}".format(workflow.cores))
print("Available system memory: {}GB".format(int(system_memory)))
if gpu_memory > 0:
   print("Total GPU memory: {}GB".format(gpu_memory))
else:
   print("No gpu found")

# print threading limits
print("Task Parallelization: ")
print("  PreScore : {}x".format(min(workflow.cores,int(100/config['prescore_cpu_load']))))
print("  VEP : {}x with {} threads each".format(min(workflow.cores,int(100/config['vep_cpu_load'])), config['vep_cpu_threads']))
print("  ESM : CPU : {}x with {} threads each (memory constraints)".format(min(workflow.cores,config['esm_cpu_slots']),config['esm_cpu_threads']))
print("  ESM : GPU : {}x (gpu memory constraints)".format(config['esm_gpu_slots']))
print("  RegSeq : {}x".format(min(workflow.cores,int(100/config['regseq_cpu_load']))))
print("  MMsplice : {}x with {} threads each (memory constraints)".format(min(workflow.cores,int(100/config['mms_cpu_load'])),config['mms_cpu_threads']))
print("  Annotate : {}x".format(min(workflow.cores,int(100/config['anno_cpu_load']))))
print("  Impute : {}x".format(min(workflow.cores,int(100/config['impute_cpu_load']))))
          
# flush output before starting workflow
print("Starting workflow",flush=True)


## allowed scattering 
scattergather:
    split=workflow.cores,

envvars:
    "CADD",


#wildcard_constraints:
#    basefile="[^/]+"

# START Rules

rule decompress:
    conda:
        "envs/environment_minimal.yml"
    input:
        "{file}.vcf.gz",
    output:
        "{file}.vcf",
    log:
        "{file}.decompress.log",
    shell:
        """
        zcat {input} > {output} 2> {log}
        """


rule prepare:
    conda:
        "envs/environment_minimal.yml"
    input:
        vcf="{file}.vcf",
        
    output:
        #prep="{file}.prepared.vcf.tmp",
        #split=directory("{file}_splits"),
        splits=scatter.split("{{file}}_splits/chunk_{scatteritem}.prepared.vcf"),
    log:
        "{file}.prepare.log",
    params:
        cadd=os.environ["CADD"],
        threads=workflow.cores,
    resources:
        # < 1GB of memory
        cpu_load=1,
    shell:
        """
        mkdir -p {wildcards.file}_splits/ 2>> {log}
        cat {input.vcf} \
        | python {params.cadd}/src/scripts/VCF2vepVCF.py \
        | grep -v '^#' \
        | sed 's/^chr//' \
        | sort -k1,1 -k2,2n -k4,4 -k5,5 \
        | uniq > {wildcards.file}_splits/full.vcf 2> {log} 

        # split
        LC=$(wc -l {wildcards.file}_splits/full.vcf | cut -f1 -d' ')
        ## if zero, stop the workflow here (as success)
        if [[ "$LC" -eq 0 ]]; then
            echo "No variants to process. Exiting." >> {log}
            # put expected files in place for this step (generated by split and the for loop below)
            touch {wildcards.file}_splits/chunk_1-of-{params.threads}.prepared.vcf
            exit 0
        fi

        LC=$(((LC / {params.threads})+1))
        
        split -l $LC --numeric-suffixes=1 --additional-suffix="-of-{params.threads}.prepared.vcf" {wildcards.file}_splits/full.vcf {wildcards.file}_splits/chunk_ 2>> {log}

        rm -f {wildcards.file}_splits/full.vcf
        
        # strip padding zeros in the file names 
        for f in {wildcards.file}_splits/chunk_*.prepared.vcf
        do
            target=$(echo "$f" | sed -E 's/(chunk_)0*([1-9][0-9]*)(-of-{params.threads}\\.prepared\\.vcf)/\\1\\2\\3/')
            if [ "$f" != "$target" ]; then
                mv -n "$f" "$target"
            fi
            
        done
        """


checkpoint prescore:
    conda:
        "envs/environment_minimal.yml"
    input:
        vcf="{file}_splits/chunk_{chunk}.prepared.vcf",
        prescored="%s/%s" % (os.environ["CADD"], config["PrescoredFolder"]),
    output:
        novel="{file}_splits/chunk_{chunk}.novel.vcf",
        prescored="{file}_splits/chunk_{chunk}.pre.tsv",
    log:
        "{file}.chunk_{chunk}.prescore.log",
    params:
        cadd=os.environ["CADD"],
    resources:
        # < 1GB of memory
        cpu_load=int(config['prescore_cpu_load']),
    shell:
        """
        # Prescoring
        echo '## Prescored variant file' > {output.prescored} 2> {log};
        # are prescored files available?
        PRESCORED_FILES=`find -L {input.prescored} -maxdepth 1 -type f -name \\*.tsv.gz | wc -l`
        cp {input.vcf} {input.vcf}.new
        if [ ${{PRESCORED_FILES}} -gt 0 ];
        then
            # loop over all prescored files: snv , indel, ... 
            for PRESCORED in $(ls {input.prescored}/*.tsv.gz)
            do
                # extract writes found to outfile, not-found to stdout
                cat {input.vcf}.new \
                | python {params.cadd}/src/scripts/extract_scored.py --header \
                    -p $PRESCORED --found_out={output.prescored}.tmp \
                > {input.vcf}.tmp 2>> {log};
                # get prescored to the outfile
                cat {output.prescored}.tmp >> {output.prescored}
                # put not-found back to the input
                mv {input.vcf}.tmp {input.vcf}.new &> {log};
            done;
            rm {output.prescored}.tmp &>> {log}
        fi
        mv {input.vcf}.new {output.novel} &>> {log}
        """


rule annotation_vep:
    conda:
        "envs/vep.yml"
    input:
        vcf="{file}_splits/chunk_{chunk}.novel.vcf",
        veppath="%s/%s" % (os.environ["CADD"], config["VEPpath"]),
    output:
        "{file}_splits/chunk_{chunk}.vep.vcf.gz",
    log:
        "{file}.chunk_{chunk}.annotation_vep.log",
    params:
        cadd=os.environ["CADD"],
        genome_build=config["GenomeBuild"],
        ensembl_db=config["EnsemblDB"],
        threads=config['vep_cpu_threads'],
    resources:
        # < 1GB of memory
        cpu_load=int(config['vep_cpu_load']),
    threads:
        config['vep_cpu_threads'],
    shell:
        """
        cat {input.vcf} \
        | vep --quiet --cache --offline --dir {input.veppath} \
            --buffer 1000 --no_stats --species homo_sapiens \
            --db_version={params.ensembl_db} --assembly {params.genome_build} \
            --format vcf --regulatory --sift b --polyphen b --per_gene --ccds --domains \
            --numbers --canonical --total_length --vcf --force_overwrite --output_file STDOUT \
            --fork {params.threads} \
        | bgzip -c > {output} 2> {log}
        """


rule annotate_esm:
    conda:
        "envs/esm.yml"
    input:
        #vcf="{file}_splits/chunk_{chunk}.vep.vcf.gz",
        vcf="{file}_splits/chunk_{chunk}.vep.vcf.gz",
        models=expand(
            "{path}/{model}.pt",
            path=config["ESMpath"],
            model=config["ESMmodels"],
        ),
        transcripts="%s/pep.%s.fa" % (config["ESMpath"], config["EnsemblDB"]),
    output:
        missens="{file}_splits/chunk_{chunk}.esm_missens.vcf.gz",
        frameshift="{file}_splits/chunk_{chunk}.esm_frameshift.vcf.gz",
        final="{file}_splits/chunk_{chunk}.esm.vcf.gz",
    log:
        "{file}.chunk_{chunk}.annotate_esm.log",
    resources:
        cpu_load=int(config['esm_cpu_load']),
        gpu_load=int(config['esm_gpu_load']),
    threads: 
        config['esm_cpu_threads'],
    params:
        cadd=os.environ["CADD"],
        models=["--model %s " % model for model in config["ESMmodels"]],
        batch_size=config["ESMbatchsize"],
        #header=config["Header"],
    
    shell:
        """
        model_directory=`dirname {input.models[0]}`;
        model_directory=`dirname $model_directory`;

        python {params.cadd}/src/scripts/lib/tools/esmScore/esmScore_missense_av_fast.py \
        --input {input.vcf} \
        --transcripts {input.transcripts} \
        --model-directory $model_directory {params.models} \
        --output {output.missens} --batch-size {params.batch_size} &> {log}

        python {params.cadd}/src/scripts/lib/tools/esmScore/esmScore_frameshift_av.py \
        --input {output.missens} \
        --transcripts {input.transcripts} \
        --model-directory $model_directory {params.models} \
        --output {output.frameshift} --batch-size {params.batch_size} &>> {log}

        python {params.cadd}/src/scripts/lib/tools/esmScore/esmScore_inFrame_av.py \
        --input {output.frameshift} \
        --transcripts {input.transcripts} \
        --model-directory $model_directory {params.models} \
        --output {output.final} --batch-size {params.batch_size} &>> {log}

        #rm -f {wildcards.file}.esm_in.vcf.gz
        """


rule annotate_regseq:
    conda:
        "envs/regulatorySequence.yml"
    input:
        vcf="{file}_splits/chunk_{chunk}.esm.vcf.gz",
        reference="%s/%s" % (config["REGSEQpath"], "reference.fa"),
        genome="%s/%s" % (config["REGSEQpath"], "reference.fa.genome"),
        model="%s/%s" % (config["REGSEQpath"], "Hyperopt400InclNegatives.json"),
        weights="%s/%s" % (config["REGSEQpath"], "Hyperopt400InclNegatives.h5"),
    output:
        "{file}_splits/chunk_{chunk}.regseq.vcf.gz",
    log:
        "{file}.chunk_{chunk}.annotate_regseq.log",
    params:
        cadd=os.environ["CADD"],
    resources:
        # roughly 4GB of memory
        cpu_load=int(config['regseq_cpu_load']),
    shell:
        """
        python {params.cadd}/src/scripts/lib/tools/regulatorySequence/predictVariants.py \
        --variants {input.vcf} \
        --model {input.model} \
        --weights {input.weights} \
        --reference {input.reference} \
        --genome {input.genome} \
        --output {output} &> {log}
        """


rule annotate_mmsplice:
    conda:
        "envs/mmsplice.yml"
    input:
        vcf="{file}_splits/chunk_{chunk}.regseq.vcf.gz",
        transcripts="%s/homo_sapiens.110.gtf" % config.get("MMSPLICEpath", ""),
        reference="%s/reference.fa" % config.get("REFERENCEpath", ""),
    output:
        mmsplice="{file}_splits/chunk_{chunk}.mmsplice.vcf.gz",
        # needed ? 
        idx="{file}_splits/chunk_{chunk}.regseq.vcf.gz.tbi",
    log:
        "{file}.chunk_{chunk}.annotate_mmsplice.log",
    params:
        cadd=os.environ["CADD"],
        mms_threads=config['mms_cpu_threads']  # Assigning the number of threads for mmsplice
    resources:
        cpu_load=int(config['mms_cpu_load']),
    threads: 
        config['mms_cpu_threads'],
    shell:
        """
        # mmsplice crashes on empty vcf files: evaluate nr of variants left
        LC=$(bgzip -dc {input.vcf} | grep -c -v '#' || true)
        bgzip -dc {input.vcf} > /dev/null
        echo "nr of lines: "
        if [[ "$LC" -eq 0 ]]; then
            echo "Empty VCF file, skipping mmsplice annotation." >> {log}
            tabix -p vcf {input.vcf} &>> {log};
            cp {input.vcf} {output.mmsplice}
        else 
            # set parallelism for tensorflow : 
            export OMP_NUM_THREADS={params.mms_threads}
            export TF_NUM_INTRAOP_THREADS={params.mms_threads}
            export TF_NUM_INTEROP_THREADS={params.mms_threads}
            # annotate
            tabix -p vcf {input.vcf} &> {log};
            KERAS_BACKEND=tensorflow python {params.cadd}/src/scripts/lib/tools/MMSplice.py -i {input.vcf} \
            -g {input.transcripts} \
            -f {input.reference} | \
            grep -v '^Variant(CHROM=' | \
            bgzip -c > {output.mmsplice} 2>> {log}
        fi
        """


rule annotation:
    conda:
        "envs/environment_minimal.yml"
    input:
        vcf=lambda wc: "{file}_splits/chunk_{chunk}.%s.vcf.gz"
        % ("mmsplice" if config["GenomeBuild"] == "GRCh38" else "regseq"),
        reference_cfg="%s/%s" % (os.environ["CADD"], config["ReferenceConfig"]),
    output:
        "{file}_splits/chunk_{chunk}.anno.tsv.gz",
    log:
        "{file}.chunk_{chunk}.annotation.log",
    params:
        cadd=os.environ["CADD"],
    resources:
        cpu_load=int(config['anno_cpu_load']),
    shell:
        """
        zcat {input.vcf} \
        | python {params.cadd}/src/scripts/annotateVEPvcf.py \
            -c {input.reference_cfg} \
        | gzip -c > {output} 2> {log}
        """


rule imputation:
    conda:
        "envs/environment_minimal.yml"
    input:
        tsv="{file}_splits/chunk_{chunk}.anno.tsv.gz",
        impute_cfg="%s/%s" % (os.environ["CADD"], config["ImputeConfig"]),
    output:
        "{file}_splits/chunk_{chunk}.csv.gz",
    log:
        "{file}.chunk_{chunk}.imputation.log",
    params:
        cadd=os.environ["CADD"],
    resources:
        cpu_load=int(config['impute_cpu_load']),
    shell:
        """
        zcat {input.tsv} \
        | python {params.cadd}/src/scripts/trackTransformation.py -b \
            -c {input.impute_cfg} -o {output} --noheader &>> {log};
        """


rule score:
    conda:
        "envs/environment_minimal.yml"
    input:
        impute="{file}_splits/chunk_{chunk}.csv.gz",
        anno="{file}_splits/chunk_{chunk}.anno.tsv.gz",
        conversion_table="%s/%s" % (os.environ["CADD"], config["ConversionTable"]),
        model_file="%s/%s" % (os.environ["CADD"], config["Model"]),
    output:
        "{file}_splits/chunk_{chunk}.novel.tsv",
    log:
        "{file}.chunk_{chunk}.score.log",
    params:
        cadd=os.environ["CADD"],
        use_anno=config["Annotation"],
        columns=config["Columns"],
    resources:
        cpu_load=config['score_cpu_load'],
    shell:
        """
        python {params.cadd}/src/scripts/predictSKmodel.py \
            -i {input.impute} -m {input.model_file} -a {input.anno} \
        | python {params.cadd}/src/scripts/max_line_hierarchy.py --all \
        | python {params.cadd}/src/scripts/appendPHREDscore.py \
            -t {input.conversion_table} > {output} 2>> {log};
    
        if [ "{params.use_anno}" = 'False' ]
        then
            cat {output} | cut -f {params.columns} | uniq > {output}.tmp 2>> {log};
            mv {output}.tmp {output} &>> {log}
        fi
        """


# def aggregate_input(wildcards):
#     # Find all chunk files for the given wildcard
#     chunk_files = glob.glob(f"{wildcards.file}_splits/{wildcards.file}.chunk_*.novel.vcf")
#     pre_files = glob.glob(f"{wildcards.file}_splits/{wildcards.file}.chunk_*.pre.tsv")
#     
#     # Combine the novel and prescore chunk files if not empty
#     output = [f for f in chunk_files + pre_files if os.path.getsize(f) > 0]
#     if not output:
#         # no output : make empty file 
#         open(f"{wildcards.file}.empty", "w").close()
#         output = [f"{wildcards.file}.empty"]
# 
#     return output



#def aggregate_input(wildcards):
#    with checkpoints.prescore.get(file=wildcards.file).output["novel"].open() as f:
#        output = ["{file}.pre.tsv"]
#        for line in f:
#            if line.strip() != "":
#                output.append("{file}.novel.tsv")
#                break
#        return output


rule join:
    conda:
        "envs/environment_minimal.yml"
    input:
        #aggregate_input,
        pre=gather.split("{{file}}_splits/chunk_{scatteritem}.pre.tsv"),
        scored=gather.split("{{file}}_splits/chunk_{scatteritem}.novel.tsv"),
    output:
        "{file,.+(?<!\\.anno)}.tsv.gz",
    log:
        "{file}.join.log",
    params:
        header=config["Header"],
    shell:
        """
        (
            echo "{params.header}";
            cat {input.pre} {input.scored} | grep -v "^##" | grep "^#" | tail -n 1;
            cat {input.pre} {input.scored}| \
            grep -v "^#" | \
            sort -k1,1 -k2,2n -k3,3 -k4,4 || true;
        ) | bgzip -c > {output} 2>> {log};
        """


# END Rules
