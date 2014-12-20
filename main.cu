#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#define MAX_FILE_SIZE 1048576
#define STORAGE_SIZE 1085440
#define DATAFILE "./data.bin"
#define OUTPUTFILE "./snapshot.bin"
#define G_WRITE 1
#define G_READ 2
#define RM 3
#define RM_RF 4
#define LS_S 5
#define LS_D 6
#define dataHead 36864
#define BASE 1030

typedef unsigned char uchar;
typedef uint32_t u32;
typedef unsigned short u16;

__device__ __managed__ uchar *volume;
__device__ __managed__ uchar tempFCB[30];
__device__ __managed__ uchar temp[64];

void init_volume() {
	int i;
    memset(volume, 0, STORAGE_SIZE * sizeof(uchar));
	for(i = 0; i < 1024; i++){
		volume[i] = 1; 
	}//0 ~ 1023 : map to free space
	//1024 ~ 1025 : file count
	//1026 ~ 1029 : time stamp 
	//file format : 20byte file name + 4 byte address + 4 byte time + 2 byte size
	//total : 1030 + 30*1024 = 31750
}
int loadBinaryFile(char *fileName, uchar *vol, int fileSize) {
    FILE *fp = fopen(fileName, "rb");
    int size;
    
	fseek(fp, 0, SEEK_END);
    size = ftell(fp);
    rewind(fp);
    fread(vol, sizeof(uchar), size, fp);
	fclose(fp);
    return size;
}

void writeBinaryFile(char *fileName, uchar *output, int fileSize) {
    FILE *fp = fopen(fileName, "wb+");
    fwrite(output, sizeof(uchar), fileSize, fp);
	fclose(fp);
}
__device__ void cpy(char *dest, char const *src){
	int i = 0;
	for(i = 0; i < 20 && src[i] != '\0';i++){
		dest[i] = src[i];
	}
}
__device__ int length(char const *a){
	int i = 0;
	
	if(a == NULL) return 0;
	while(a[i] !='\0' && i < 20){
		i += 1;
	}
	return i;
}
__device__ bool cmp(char const *a, char const *b){
	int len = length(a);
	int lenb = length(b);
	int i;

	if(len == 0 || lenb == 0) return false;
	if(len != lenb) return false;
	else{
		for(i = 0; i < len; i++){
			if(a[i] != b[i]) return false;
		}
		return true;
	}
	return false;
}
__device__ u32* getAddr(int i){
	return (u32*)volume + BASE + i*30 + 20;
}
__device__ char* getName(int i){
	return (char*)volume + BASE + i*30;
}
__device__ u16 getSize(int i){
	return (u16)*(volume + BASE + i*30 + 28);
}
__device__ u32 getTime(int i){
	return (u32)*(volume + BASE + i*30 + 24);
}
__device__ void swapFCB(int a, int b){
	int i;
	int indexA = BASE + a*30;
	int indexB = BASE + b*30;
	for(i = 0; i < 26; i++){
		tempFCB[i] = volume[indexA + i];
	}
	for(i = 0; i < 26; i++){
		volume[indexA + i] = volume[indexB + i];
	}
	for(i = 0; i < 26; i++){
		volume[indexB + i] = tempFCB[i];
	}
}
__device__ void swapContent(int a, int b){
	int i, j;
	int indexA = dataHead + (a << 10);
	int indexB = dataHead + (b << 10);
	for(i = 0; i < 16; i++){
		for(j = 0; j < 64; j++){
			temp[j] = volume[indexA + (i << 6) + j];
		}
		for(j = 0; j < 64; j++){
			volume[indexA + (i << 6) + j] = volume[indexB + (i << 6) + j];
		}
		for(j = 0; j < 64; j++){
			volume[indexB + (i <<6) + j] = temp[j];
		}
	}
}
__device__ void sortBySize(){
	int i, j;
	u16 *fileCount = (u16*)volume + 1024;
	
	for(i = 0; i < *fileCount; i++){
		for(j = 0; j < *fileCount - i -1; j++){
			if(getSize(j) < getSize(j+1)){
				swapFCB(j, j+1);
				swapContent(j, j+1);
			}
			else if(getSize(j) == getSize(j+1)){
				if(getTime(j) > getTime(j+1)){
					swapFCB(j, j+1);
					swapContent(j, j+1);
				}
			}	
		}
	}
}
__device__ void sortByTime(){
	int i, j;
	u16 *fileCount = (u16*)volume + 1024;
	
	for(i = 0; i < *fileCount; i++){
		for(j = 0; j < *fileCount - i - 1; j++){
			if(getTime(j) > getTime(j+1)){
				swapFCB(j, j+1);
				swapContent(j, j+1);
			}
		}
	}
}

__device__ u32 findFreeSpace(){
	int i;
	for(i = 0; i < 1024; i++){
		if(volume[i] == 1){
			volume[i] = 0;
			break;
		}
	}
	return dataHead +  (i << 10);
}

__device__ u32 open(char const *name, int type) {
	u16 *fileCount = (u16*)(volume + 1024);
	u32 *address = NULL;
	int i;
	char *fileName;
	printf("open\n");
	
	for(i = 0; i < *fileCount; i++){//linear search for file
		fileName = (char*)&volume[BASE +  i*30];
		if(cmp(name, fileName) == true){
			address = getAddr(i);
			if(type == G_WRITE)memset(volume + *address, 0, sizeof(char) * 1024);
			break;
		}
	}
	if(address == NULL && type == G_WRITE){//file not found, create new
		cpy((char*)(volume + BASE + (*fileCount)*30), name);
		volume[*fileCount] = 0;
		*fileCount += 1;
		printf("create new file\n");
		address = getAddr(fileCount);
	}
	printf("fileCount : %d\n", *fileCount);
    return *address;
}

__device__ void remove(u32 address){
	int index = (address - dataHead) >> 10;
	//int i;
	//u32 *addr;
	u16 *fileCount = (u16*)volume + 1024;
	
	volume[index] = 1;
	memset(volume + BASE + index*30, 0, 30 * sizeof(char));//clean FCB
	if(volume[dataHead - 1] == 0)sortByTime();
	else sortBySize();
	*fileCount -= 1;
/*
	for(i = 0; i < *fileCount; i++){
		addr = volume + BASE + i*26 + 20;	
		if(*addr == address){
			memset(volume+BASE+i*26, 0, 26*sizeof(char));//clean FCB
			break;
		}
	}
*/
}

__device__ void write(uchar *src, int size, u32 fp) {
	int i;
	int index = (fp - dataHead) >> 10;
	u32 *time = (u32*)volume + 1026;
	printf("%d\n", fp);
	for(i = 0; i < size; i ++){
		volume[fp + i] = src[i];
	}
	*(volume + BASE + index*30 + 24) = *time;
	*(volume + BASE + index*30 + 28) = size;
	*time = *time + 1;
	printf("write\n");
}

__device__ void read(uchar *dest, int size, u32 fp) {
	int i;
	u32 *time = (u32*)volume + 1026;
	
	for(i = 0; i < size; i++){
		dest[i] = volume[fp + i];
	}
	*time = *time + 1;
}

__device__ void printFCB_D(){
	u16 *fileCount = (u16*)(volume + 1024);
	int i;
	
	printf("===sort by file time===\n");
	for(i = 0; i < *fileCount; i++){
		printf("%s\n", getName(i));
	}
}
__device__ void printFCB_S(){
	u16 *fileCount = (u16*)(volume + 1024);
	int i;

	printf("===sort by file size===\n");
	for(i = 0; i < *fileCount; i++){
		printf("%s %d\n", getName(i), getSize(i));
	}
}
__device__ void gsys(int cmd) {
	printf("gsys\n");
	if(cmd == LS_S){
		if(volume[dataHead - 1] == 0)sortBySize();
		printFCB_S();
	}
	else if(cmd == LS_D){
		if(volume[dataHead - 1] == 1)sortByTime();
		printFCB_D();
	}
}
__device__ void gsys(int cmd, char const *fileName) {
	u16* fileCount = (u16*)volume + 1024;
	int i;
	if(cmd == RM){
		for(i = 0; i < *fileCount; i++){
			if(cmp(getName(i), fileName) == true){
				remove(*(getAddr(i)));
				break;
			}
		}	
	}
}
__global__ void mykernel(uchar *input, uchar *output) {
    printf("kernel start\n");
	//####kernel start####
    u32 fp = open("t.txt\0", G_WRITE);
    printf("fp: %d\n");
	write(input, 64, fp);
    fp = open("b.txt\0", G_WRITE);
    write(input+32, 32, fp);
    fp = open("t.txt\0", G_WRITE);
    write(input+32, 32, fp);
    read(output, 32, fp);
    gsys(LS_D);
    gsys(LS_S);
    fp = open("b.txt\0", G_WRITE);
    write(input + 64, 12, fp);
    gsys(LS_S);
    gsys(LS_D);
    gsys(RM, "t.txt\0");
    gsys(LS_S);
    //####kernel end####
}

int main() {
    cudaMallocManaged(&volume, STORAGE_SIZE);
    init_volume();

    uchar *input, *output;
    cudaMallocManaged(&input, MAX_FILE_SIZE);
    cudaMallocManaged(&output, MAX_FILE_SIZE);
    loadBinaryFile(DATAFILE, input, MAX_FILE_SIZE);

    cudaSetDevice(1);
    mykernel<<<1, 1>>>(input, output);
    cudaDeviceSynchronize();
    writeBinaryFile(OUTPUTFILE, output, MAX_FILE_SIZE);
    cudaDeviceReset();

    return 0;
}
